# frozen_string_literal: true

# name: discourse-digest-campaigns
# about: Admin-defined digest campaigns from a SQL segment + up to 3 random topic sets (or a "regular digest" mode that sends the normal digest, with optional VSL-flow overrides for promo-digest-injector). Populate once on create; optional scheduled send_at; throttled batched sending; admin UI.
# version: 1.12.0
# authors: you
# required_version: 3.0.0

enabled_site_setting :digest_campaigns_enabled

# This adds the plugin entry under /admin/plugins (label from client locale: js.digest_campaigns.title)
add_admin_route "digest_campaigns.title", "digest-campaigns"

after_initialize do
  module ::DigestCampaigns
    PLUGIN_NAME = "discourse-digest-campaigns"
    QUEUE_TABLE = "digest_campaign_queue"
    CAMPAIGNS_TABLE = "digest_campaigns"

    def self.minute_bucket_key
      (Time.now.utc.to_i / 60).to_i
    end

    def self.redis_rate_key(bucket)
      "digest_campaigns:sent:#{bucket}"
    end

    def self.validate_campaign_sql!(sql)
      s = sql.to_s.strip
      raise ArgumentError, "campaign SQL is blank" if s.empty?
      raise ArgumentError, "campaign SQL must NOT contain semicolons" if s.include?(";")
      unless s.match?(/\A(select|with)\b/i)
        raise ArgumentError, "campaign SQL must start with SELECT or WITH"
      end
      s
    end

    def self.parse_topic_set_csv(csv)
      s = csv.to_s.strip
      return [] if s.blank?
      s.split(",").map { |x| x.strip }.reject(&:blank?).map(&:to_i).select { |n| n > 0 }
    end

    # Accepts a comma / newline / pipe separated string (or an array) and returns a
    # de-duplicated (case-insensitive) list of non-blank source names.
    def self.parse_source_list(raw)
      items = raw.is_a?(Array) ? raw : raw.to_s.split(/[\n,|]+/)
      items.map { |x| x.to_s.strip }.reject(&:blank?).uniq { |x| x.downcase }
    end

    # Runs the block with the VSL override that promo-digest-injector reads from
    # Thread.current[:digest_campaign_vsl_override]. `opts` keys:
    #   direct, skip_coinflip, ignore_min_emails, allowed_sources
    # The injector writes its outcome to override[:result] (a Hash with :queued etc.).
    # Returns [block_result, override_hash].
    def self.with_vsl_override(opts)
      override = {
        direct: opts[:direct] == true,
        skip_coinflip: opts[:skip_coinflip] == true,
        ignore_min_emails: opts[:ignore_min_emails] == true,
        allowed_sources: parse_source_list(opts[:allowed_sources]),
        result: nil
      }
      Thread.current[:digest_campaign_vsl_override] = override
      [yield, override]
    ensure
      Thread.current[:digest_campaign_vsl_override] = nil
    end

    # ------------------------------------------------------------------
    # Regular-digest campaign tracking (digest-append3-links-and-trim-excerpt + digest-report2)
    # ------------------------------------------------------------------
    # A regular-digest campaign falls through to core's digest, where the append plugin
    # (::DigestAppendData) stamps a purely random 20-digit email_id on the links. digest-report2
    # only derives campaignid from campaign-shaped ids ("0000" + cid + "000" + random), so those
    # sends were logged with campaignid NULL. While the block runs, the append plugin's
    # generate_email_id returns a campaign-shaped id for this campaign instead.
    module AppendEmailIdOverride
      def generate_email_id(*args, **kwargs)
        cid = Thread.current[:digest_campaign_regular_campaign_id].to_i
        if cid > 0
          ::DigestCampaigns::DigestAppendData.generate_email_id(campaign_id: cid)
        else
          super
        end
      end
    end

    def self.patch_append_email_id!
      return false unless defined?(::DigestAppendData) && ::DigestAppendData.respond_to?(:generate_email_id)
      sc = ::DigestAppendData.singleton_class
      sc.prepend(AppendEmailIdOverride) unless sc.ancestors.include?(AppendEmailIdOverride)
      true
    rescue => e
      Rails.logger.warn("[digest-campaigns] append email_id patch failed: #{e.class}: #{e.message}")
      false
    end

    def self.with_regular_digest_campaign_id(campaign_id)
      # Patched lazily so plugin load order doesn't matter.
      patch_append_email_id!
      Thread.current[:digest_campaign_regular_campaign_id] = campaign_id
      yield
    ensure
      Thread.current[:digest_campaign_regular_campaign_id] = nil
    end

    def self.vsl_override_opts_for(campaign)
      {
        direct: campaign.vsl_direct,
        skip_coinflip: campaign.vsl_skip_coinflip,
        ignore_min_emails: campaign.vsl_ignore_min_emails,
        allowed_sources: campaign.vsl_allowed_sources
      }
    end

    # ------------------------------------------------------------------
    # Per-campaign SMTP provider constraints (discourse-multi-smtp-router)
    # ------------------------------------------------------------------
    # The router reads these headers in its before_email_send hook, narrows its provider
    # pool, and strips them before delivery. Names must match MultiSmtpRouter::HDR_ONLY_PROVIDERS
    # / HDR_AVOID_PROVIDERS (kept as literals so load order between the plugins doesn't matter).
    SMTP_ONLY_PROVIDERS_HEADER = "X-Multi-SMTP-Router-Only-Providers"
    SMTP_AVOID_PROVIDERS_HEADER = "X-Multi-SMTP-Router-Avoid-Providers"
    SMTP_ROUTING_REASON_HEADER = "X-Multi-SMTP-Router-Routing-Reason"
    SMTP_NO_POOL_REASON_PREFIX = "campaign_providers_no_pool"

    # Provider ids are matched exactly (case-sensitive) by the router, so only trim + de-dupe.
    def self.parse_provider_id_list(raw)
      items = raw.is_a?(Array) ? raw : raw.to_s.split(/[\n,|]+/)
      items.map { |x| x.to_s.strip }.reject(&:blank?).uniq
    end

    def self.smtp_router_active?
      defined?(::MultiSmtpRouter) && ::MultiSmtpRouter.enabled?
    rescue
      false
    end

    # Enabled provider ids configured in the router (empty when the router isn't installed/enabled).
    def self.smtp_router_provider_ids
      return [] unless smtp_router_active?
      ::MultiSmtpRouter.providers.map { |p| p[:id].to_s }.reject(&:blank?).uniq
    rescue
      []
    end

    # Validates the lists for a campaign being created / test-sent. Returns
    # { smtp_only_provider_ids: [...], smtp_avoid_provider_ids: [...] }.
    def self.smtp_provider_constraints_from(only_raw, avoid_raw)
      only = parse_provider_id_list(only_raw)
      avoid = parse_provider_id_list(avoid_raw)

      if only.present? || avoid.present?
        unless smtp_router_active?
          raise ArgumentError,
                "SMTP provider constraints need discourse-multi-smtp-router installed and enabled"
        end

        known = smtp_router_provider_ids
        unknown = (only + avoid).uniq - known
        if unknown.any?
          raise ArgumentError,
                "Unknown or disabled SMTP provider id(s): #{unknown.join(', ')} " \
                  "(enabled providers: #{known.join(', ').presence || 'none'})"
        end

        both = only & avoid
        if both.any?
          raise ArgumentError, "Provider id(s) in both 'use only' and 'avoid': #{both.join(', ')}"
        end

        if only.present? && (only - avoid).empty?
          raise ArgumentError, "No provider left to send with after applying 'avoid'"
        end
      end

      { smtp_only_provider_ids: only, smtp_avoid_provider_ids: avoid }
    end

    def self.smtp_provider_opts_for(campaign)
      {
        only: Array(campaign.smtp_only_provider_ids),
        avoid: Array(campaign.smtp_avoid_provider_ids)
      }
    end

    # Unwraps a lazy ActionMailer::MessageDelivery into the Mail::Message.
    def self.real_message(message)
      message.respond_to?(:__getobj__) ? message.__getobj__ : message
    end

    # Stamps the constraint headers onto the message (call right before Email::Sender).
    # Raises when constraints are set but the router can't honor them, so the send is not
    # silently routed through the default SMTP.
    def self.apply_smtp_provider_constraints!(message, only: [], avoid: [])
      only = parse_provider_id_list(only)
      avoid = parse_provider_id_list(avoid)
      return message if only.empty? && avoid.empty?

      unless smtp_router_active?
        raise "Campaign has SMTP provider constraints but discourse-multi-smtp-router is not enabled"
      end

      real = real_message(message)
      return message unless real.respond_to?(:header)

      real.header[SMTP_ONLY_PROVIDERS_HEADER] = only.join(",") if only.any?
      real.header[SMTP_AVOID_PROVIDERS_HEADER] = avoid.join(",") if avoid.any?
      real
    end

    # After Email::Sender#send: the router's reason when it refused to deliver because no
    # provider satisfied the campaign constraints, else nil.
    def self.smtp_constraints_block_reason(message)
      real = real_message(message)
      return nil unless real.respond_to?(:header)
      reason = real.header[SMTP_ROUTING_REASON_HEADER]&.value.to_s
      reason.start_with?(SMTP_NO_POOL_REASON_PREFIX) ? reason : nil
    rescue
      nil
    end

    def self.pick_random_topic_set(topic_sets)
      sets =
        Array(topic_sets)
          .map { |a| Array(a).map(&:to_i).select { |n| n > 0 } }
          .reject(&:blank?)
      return [] if sets.empty?
      sets[SecureRandom.random_number(sets.length)]
    end

    # 3 random forum posts created between 24 and 72 hours ago (used for campaign "popular posts" section)
    def self.fetch_random_popular_posts(limit = 3)
      lim = limit.to_i
      lim = 3 if lim <= 0
      lim = 50 if lim > 50

      now = (defined?(Time.zone) && Time.zone) ? Time.zone.now : Time.now
      newest = now - 24.hours
      oldest = now - 72.hours

      regular_type =
        begin
          Post.types[:regular]
        rescue
          1
        end

      Post
        .joins(:topic)
        .where("posts.created_at >= ? AND posts.created_at <= ?", oldest, newest)
        .where("posts.deleted_at IS NULL")
        .where(user_deleted: false)
        .where(hidden: false)
        .where(post_type: regular_type)
        .where("topics.deleted_at IS NULL")
        .where("topics.archetype = ?", Archetype.default)
        .where("topics.visible = true")
        .includes(:topic, :user)
        .order(Arel.sql("RANDOM()"))
        .limit(lim)
        .to_a
    end
  end

  require_dependency "email/sender"
  require_dependency "email/message_builder"

  # IMPORTANT: run campaigns through the REAL digest action so digest plugins trigger.
  require_relative "lib/digest_campaigns/user_notifications_extension"
  ::UserNotifications.class_eval do
    prepend ::DigestCampaigns::UserNotificationsExtension
  end

  Discourse::Application.routes.append do
    # Admin UI entry (supported plugin-admin pattern)
    get "/admin/plugins/digest-campaigns" => "admin/plugins#index", constraints: StaffConstraint.new

    # JSON API endpoints (explicit .json)
    namespace :admin do
      get    "/digest-campaigns.json" => "digest_campaigns#index"
      post   "/digest-campaigns.json" => "digest_campaigns#create"
      put    "/digest-campaigns/:id/enable.json" => "digest_campaigns#enable"
      put    "/digest-campaigns/:id/disable.json" => "digest_campaigns#disable"
      post   "/digest-campaigns/:id/test.json" => "digest_campaigns#test_send"
      post   "/digest-campaigns/test-draft.json" => "digest_campaigns#test_draft"
      post   "/digest-campaigns/count.json" => "digest_campaigns#count_records"
      post   "/digest-campaigns/regenerate.json" => "digest_campaigns#regenerate"
      get    "/digest-campaigns/:id.json" => "digest_campaigns#show"
      get    "/digest-campaigns/hardsale-email-html/:id.json" => "digest_campaigns#hardsale_email_html"
      get    "/digest-campaigns/bundle-email/:id.json" => "digest_campaigns#bundle_email_html"
      get    "/digest-campaigns/vsl2html-email/:id.json" => "digest_campaigns#vsl2html_email_html"
      get    "/digest-campaigns/web2html-email/:id.json" => "digest_campaigns#web2html_email_html"
      delete "/digest-campaigns/:id.json" => "digest_campaigns#destroy"
    end

    # NOTE: Redirect route REMOVED to avoid /admin/digest-campaigns.json being redirected.
    # (Previously: get "/admin/digest-campaigns" => redirect("/admin/plugins/digest-campaigns"))
  end

  require_relative "lib/digest_campaigns/aiwrite_hardsale_service" if File.exist?(File.join(__dir__, "lib/digest_campaigns/aiwrite_hardsale_service.rb"))
  require_relative "lib/digest_campaigns/gemini_regeneration_service"
  require_relative "app/models/digest_campaigns/campaign"
  require_relative "app/jobs/scheduled/digest_campaign_poller"
  require_relative "app/jobs/regular/digest_campaign_send_batch"
  require_relative "app/controllers/admin/digest_campaigns_controller"
end

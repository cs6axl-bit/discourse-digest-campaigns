# frozen_string_literal: true

# name: discourse-digest-campaigns
# about: Admin-defined digest campaigns from a SQL segment + up to 3 random topic sets. Populate once on create; optional scheduled send_at; throttled batched sending; admin UI.
# version: 1.8.4
# authors: you
# required_version: 3.0.0

enabled_site_setting :digest_campaigns_enabled

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
    # Convenience redirect
    get "/admin/digest-campaigns" => redirect("/admin/plugins/digest-campaigns"), constraints: StaffConstraint.new

    # JSON API endpoints (explicit .json)
    namespace :admin do
      get    "/digest-campaigns.json" => "digest_campaigns#index"
      post   "/digest-campaigns.json" => "digest_campaigns#create"
      put    "/digest-campaigns/:id/enable.json" => "digest_campaigns#enable"
      put    "/digest-campaigns/:id/disable.json" => "digest_campaigns#disable"
      post   "/digest-campaigns/:id/test.json" => "digest_campaigns#test_send"
      delete "/digest-campaigns/:id.json" => "digest_campaigns#destroy"
    end
  end

  require_relative "app/models/digest_campaigns/campaign"
  require_relative "app/jobs/scheduled/digest_campaign_poller"
  require_relative "app/jobs/regular/digest_campaign_send_batch"
  require_relative "app/controllers/admin/digest_campaigns_controller"
end

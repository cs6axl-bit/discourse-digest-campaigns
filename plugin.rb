# frozen_string_literal: true

# name: discourse-digest-campaigns
# about: Admin-defined digest campaigns from a SQL segment + up to 3 random topic sets. Populate once on create; optional scheduled send_at; throttled batched sending; admin UI.
# version: 1.7.1
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
  end

  require_dependency "email/sender"
  require_dependency "email/message_builder"

  # Option A: extend core digest mailer to render the real digest template with our topics
  require_relative "lib/digest_campaigns/user_notifications_extension"
  ::UserNotifications.class_eval do
    include ::DigestCampaigns::UserNotificationsExtension
  end

  Discourse::Application.routes.append do
    get "/admin/plugins/digest-campaigns" => "admin/plugins#index", constraints: StaffConstraint.new
    get "/admin/digest-campaigns" => redirect("/admin/plugins/digest-campaigns"), constraints: StaffConstraint.new

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

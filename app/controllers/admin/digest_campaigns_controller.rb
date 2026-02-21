# frozen_string_literal: true

module Admin
  class DigestCampaignsController < Admin::AdminController
    requires_plugin ::DigestCampaigns::PLUGIN_NAME

    def index
      rows = DigestCampaigns::Campaign.order("created_at DESC").limit(200).map do |c|
        c.as_json.merge(
          queued_count: queue_count(c.campaign_key, "queued"),
          processing_count: queue_count(c.campaign_key, "processing"),
          sent_count: queue_count(c.campaign_key, "sent"),
          failed_count: queue_count(c.campaign_key, "failed"),
          skipped_unsubscribed_count: queue_count(c.campaign_key, "skipped_unsubscribed")
        )
      end
      render_json_dump(campaigns: rows)
    end

    def create
      key = params.require(:campaign_key).to_s.strip
      sql = ::DigestCampaigns.validate_campaign_sql!(params.require(:selection_sql).to_s)

      set1 = ::DigestCampaigns.parse_topic_set_csv(params[:topic_set_1])
      set2 = ::DigestCampaigns.parse_topic_set_csv(params[:topic_set_2])
      set3 = ::DigestCampaigns.parse_topic_set_csv(params[:topic_set_3])
      topic_sets = [set1, set2, set3].reject(&:blank?)

      raise ArgumentError, "You must provide at least one topic set (topic_set_1/2/3)" if topic_sets.empty?
      raise ArgumentError, "You can provide at most 3 topic sets" if topic_sets.length > 3

      send_at = parse_send_at(params[:send_at])
      test_email = params[:test_email].to_s.strip

      c = DigestCampaigns::Campaign.new(
        campaign_key: key,
        selection_sql: sql,
        enabled: true,
        topic_sets: topic_sets,
        send_at: send_at
      )
      c.save!

      populate_queue_for_campaign!(c)
      c.update_columns(last_error: nil, last_populated_at: Time.zone.now, updated_at: Time.zone.now)

      test_result = test_email.present? ? send_test_now!(c, test_email) : nil

      render_json_dump(ok: true, campaign: c.as_json, test: test_result)
    rescue => e
      render_json_error(e.message)
    end

    def enable
      c = find_campaign
      c.update!(enabled: true)
      render_json_dump(ok: true, campaign: c.as_json)
    rescue => e
      render_json_error(e.message)
    end

    def disable
      c = find_campaign
      c.update!(enabled: false)
      render_json_dump(ok: true, campaign: c.as_json)
    rescue => e
      render_json_error(e.message)
    end

    def destroy
      c = find_campaign
      c.destroy!
      render_json_dump(ok: true)
    rescue => e
      render_json_error(e.message)
    end

    def test_send
      c = find_campaign
      test_email = params.require(:test_email).to_s.strip
      res = send_test_now!(c, test_email)
      render_json_dump(ok: true, test: res)
    rescue => e
      render_json_error(e.message)
    end

    private

    def find_campaign
      DigestCampaigns::Campaign.find(params.require(:id))
    end

    def queue_count(campaign_key, status)
      DB.query_single(<<~SQL, k: campaign_key.to_s, s: status.to_s).first.to_i
        SELECT COUNT(*) FROM #{::DigestCampaigns::QUEUE_TABLE}
        WHERE campaign_key = :k AND status = :s
      SQL
    end

    def parse_send_at(v)
      s = v.to_s.strip
      return nil if s.blank?
      Time.zone.parse(s)
    rescue
      raise ArgumentError, "Invalid send_at datetime: #{s}"
    end

    def populate_queue_for_campaign!(campaign)
      sql = ::DigestCampaigns.validate_campaign_sql!(campaign.selection_sql)

      DB.exec(<<~SQL, campaign_key: campaign.campaign_key.to_s, nb: campaign.send_at)
        INSERT INTO #{::DigestCampaigns::QUEUE_TABLE}
          (campaign_key, user_id, chosen_topic_ids, not_before, status, created_at, updated_at)
        SELECT
          :campaign_key AS campaign_key,
          src.user_id::int AS user_id,
          '{}'::int[] AS chosen_topic_ids,
          :nb AS not_before,
          'queued' AS status,
          NOW() AS created_at,
          NOW() AS updated_at
        FROM (#{sql}) src
        ON CONFLICT (campaign_key, user_id)
        DO UPDATE SET
          status = CASE
            WHEN #{::DigestCampaigns::QUEUE_TABLE}.status = 'sent' THEN 'sent'
            ELSE 'queued'
          END,
          not_before = CASE
            WHEN #{::DigestCampaigns::QUEUE_TABLE}.status = 'sent' THEN #{::DigestCampaigns::QUEUE_TABLE}.not_before
            ELSE EXCLUDED.not_before
          END,
          chosen_topic_ids = CASE
            WHEN #{::DigestCampaigns::QUEUE_TABLE}.status = 'sent' THEN #{::DigestCampaigns::QUEUE_TABLE}.chosen_topic_ids
            WHEN cardinality(#{::DigestCampaigns::QUEUE_TABLE}.chosen_topic_ids) > 0 THEN #{::DigestCampaigns::QUEUE_TABLE}.chosen_topic_ids
            ELSE '{}'::int[]
          END,
          locked_at = NULL,
          updated_at = NOW()
      SQL
    end

    def send_test_now!(campaign, test_email)
      user = User.find_by_email(test_email)
      raise "Test email not found as a Discourse user: #{test_email}" if user.nil?

      chosen = ::DigestCampaigns.pick_random_topic_set(campaign.topic_sets)
      raise "Campaign has no topic sets configured" if chosen.blank?

      message =
        UserNotifications.digest(
          user,
          campaign_topic_ids: chosen,
          campaign_key: campaign.campaign_key.to_s,
          campaign_since: campaign.send_at
        )

      Email::Sender.new(message, :digest).send

      { sent_to: test_email, user_id: user.id, chosen_topic_ids: chosen, campaign_key: campaign.campaign_key }
    end
  end
end

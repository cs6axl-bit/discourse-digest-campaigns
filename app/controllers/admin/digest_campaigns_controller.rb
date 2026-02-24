# frozen_string_literal: true

require "securerandom"

module Admin
  class DigestCampaignsController < Admin::AdminController
    requires_plugin ::DigestCampaigns::PLUGIN_NAME

    PER_PAGE = 30

    def index
      page = (params[:page].to_i <= 0) ? 1 : params[:page].to_i
      per_page = PER_PAGE
      offset = (page - 1) * per_page

      total = DigestCampaigns::Campaign.count
      total_pages = (total.to_f / per_page).ceil

      rows = DigestCampaigns::Campaign.order("created_at DESC").limit(per_page).offset(offset).map do |c|
        c.as_json.merge(
          queued_count: queue_count(c.campaign_key, "queued"),
          processing_count: queue_count(c.campaign_key, "processing"),
          sent_count: queue_count(c.campaign_key, "sent"),
          failed_count: queue_count(c.campaign_key, "failed"),
          skipped_unsubscribed_count: queue_count(c.campaign_key, "skipped_unsubscribed")
        )
      end

      render_json_dump(
        campaigns: rows,
        meta: {
          page: page,
          per_page: per_page,
          total: total,
          total_pages: total_pages
        }
      )
    end

    def create
      key = params.require(:campaign_key).to_s.strip
      sql = ::DigestCampaigns.validate_campaign_sql!(params.require(:selection_sql).to_s)

      exclude_recent = truthy_param?(params[:exclude_recent_from_queue], default: true)
      exclude_days = int_param?(params[:exclude_recent_from_queue_days], default: 1)
      exclude_days = 0 if exclude_days < 0
      exclude_days = 3650 if exclude_days > 3650

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

      populate_queue_for_campaign!(
        c,
        exclude_recent_from_queue: exclude_recent,
        exclude_recent_days: exclude_days
      )
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

    # Send a test email using the *draft* form fields, without creating/saving a campaign.
    def test_draft
      key = params[:campaign_key].to_s.strip
      key = "draft_#{SecureRandom.hex(4)}" if key.blank?

      sql = ::DigestCampaigns.validate_campaign_sql!(params.require(:selection_sql).to_s)

      set1 = ::DigestCampaigns.parse_topic_set_csv(params[:topic_set_1])
      set2 = ::DigestCampaigns.parse_topic_set_csv(params[:topic_set_2])
      set3 = ::DigestCampaigns.parse_topic_set_csv(params[:topic_set_3])
      topic_sets = [set1, set2, set3].reject(&:blank?)

      raise ArgumentError, "You must provide at least one topic set (topic_set_1/2/3)" if topic_sets.empty?
      raise ArgumentError, "You can provide at most 3 topic sets" if topic_sets.length > 3

      test_email = params.require(:test_email).to_s.strip
      send_at = parse_send_at(params[:send_at])

      # Ensure SQL is at least syntactically valid; also a quick sanity check the segment returns user_id
      verify_selection_sql_has_user_id!(sql)

      chosen = ::DigestCampaigns.pick_random_topic_set(topic_sets)
      res = send_test_digest!(campaign_key: key, test_email: test_email, topic_ids: chosen, send_at: send_at)
      render_json_dump(ok: true, test: res)
    rescue => e
      render_json_error(e.message)
    end

    # Count how many rows the supplied selection_sql would return.
    def count_records
      sql = ::DigestCampaigns.validate_campaign_sql!(params.require(:selection_sql).to_s)

      exclude_recent = truthy_param?(params[:exclude_recent_from_queue], default: true)
      exclude_days = int_param?(params[:exclude_recent_from_queue_days], default: 1)
      exclude_days = 0 if exclude_days < 0
      exclude_days = 3650 if exclude_days > 3650

      effective_sql = apply_recent_queue_exclusion(
        sql,
        exclude_recent_from_queue: exclude_recent,
        exclude_recent_days: exclude_days
      )
      count = DB.query_single("SELECT COUNT(*) FROM (#{effective_sql}) src").first.to_i
      render_json_dump(ok: true, count: count)
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

    def populate_queue_for_campaign!(campaign, exclude_recent_from_queue: true, exclude_recent_days: 1)
      sql = ::DigestCampaigns.validate_campaign_sql!(campaign.selection_sql)
      sql = apply_recent_queue_exclusion(
        sql,
        exclude_recent_from_queue: exclude_recent_from_queue,
        exclude_recent_days: exclude_recent_days
      )

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

    # Exclude users who have any queue record within the last N days.
    # - For regular (non-delayed) queue rows (not_before IS NULL): exclude if created_at is within timeframe.
    # - For delayed queue rows (not_before IS NOT NULL): exclude ONLY if actually sent within timeframe.
    def apply_recent_queue_exclusion(selection_sql, exclude_recent_from_queue:, exclude_recent_days:)
      return selection_sql unless exclude_recent_from_queue

      days = exclude_recent_days.to_i
      return selection_sql if days <= 0

      cutoff = Time.zone.now - days.days

      # Embed quoted timestamp safely.
      cutoff_sql = ActiveRecord::Base.connection.quote(cutoff)

      <<~SQL
        WITH src AS (
          #{selection_sql}
        )
        SELECT src.*
        FROM src
        WHERE NOT EXISTS (
          SELECT 1
          FROM #{::DigestCampaigns::QUEUE_TABLE} q
          WHERE q.user_id = src.user_id::int
            AND (
              (q.not_before IS NULL AND q.created_at >= #{cutoff_sql})
              OR
              (q.not_before IS NOT NULL AND q.status = 'sent' AND q.sent_at IS NOT NULL AND q.sent_at >= #{cutoff_sql})
            )
        )
      SQL
    end

    def truthy_param?(v, default: false)
      return default if v.nil?
      s = v.to_s.strip.downcase
      return true if %w[1 true t yes y on].include?(s)
      return false if %w[0 false f no n off].include?(s)
      default
    end

    def int_param?(v, default: 0)
      return default if v.nil?
      Integer(v)
    rescue
      default
    end

    def send_test_now!(campaign, test_email)
      chosen = ::DigestCampaigns.pick_random_topic_set(campaign.topic_sets)
      raise "Campaign has no topic sets configured" if chosen.blank?
      send_test_digest!(
        campaign_key: campaign.campaign_key.to_s,
        test_email: test_email,
        topic_ids: chosen,
        send_at: campaign.send_at,
        campaign_id: campaign.id
      )
    end

    def send_test_digest!(campaign_key:, test_email:, topic_ids:, send_at: nil, campaign_id: nil)
      user = User.find_by_email(test_email)
      raise "Test email not found as a Discourse user: #{test_email}" if user.nil?

      raise "No topic ids provided" if topic_ids.blank?

      message =
        UserNotifications.digest(
          user,
          campaign_topic_ids: topic_ids,
          campaign_key: campaign_key.to_s,
          campaign_since: send_at,
          campaign_id: campaign_id
        )

      Email::Sender.new(message, :digest).send

      {
        sent_to: test_email,
        user_id: user.id,
        chosen_topic_ids: topic_ids,
        campaign_key: campaign_key.to_s,
        campaign_id: campaign_id
      }
    end

    def verify_selection_sql_has_user_id!(sql)
      # Wrap and select user_id to validate presence. We only fetch 1 row, so it should be cheap.
      DB.query_single("SELECT src.user_id FROM (#{sql}) src LIMIT 1")
      true
    rescue => e
      raise ArgumentError, "selection_sql must return a column named user_id (and be valid SQL). Error: #{e.message}"
    end
  end
end

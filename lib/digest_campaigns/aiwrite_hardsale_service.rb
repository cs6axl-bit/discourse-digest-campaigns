# frozen_string_literal: true

require "json"

module ::DigestCampaigns
  module AiwriteHardsaleService
    EMPTY_SELECTION_SQL = "SELECT NULL::integer AS user_id WHERE 1=0"

    def self.find_by_source_topic_id(source_topic_id)
      topic_id = source_topic_id.to_i
      return nil if topic_id <= 0

      row =
        DB.query(<<~SQL, topic_id: topic_id).first
          SELECT
            id,
            source_topic_id,
            subject_titles_json,
            preheaders_json,
            preheader,
            html_full
          FROM aiwrites_hardsale_email_htmls
          WHERE source_topic_id = :topic_id
            AND COALESCE(html_full, '') <> ''
          ORDER BY id DESC
          LIMIT 1
        SQL

      return nil unless row.present?

      subjects = normalize_fixed_length_array(parse_json_string_array(row.subject_titles_json), 3)
      preheaders = normalize_fixed_length_array(parse_json_string_array(row.preheaders_json), 2)

      if preheaders.all?(&:blank?) && row.preheader.to_s.strip.present?
        preheaders[0] = row.preheader.to_s.strip
      end

      {
        id: row.id.to_i,
        source_topic_id: row.source_topic_id.to_i,
        subject_line_1: subjects[0],
        subject_line_2: subjects[1],
        subject_line_3: subjects[2],
        preheader_line_1: preheaders[0],
        preheader_line_2: preheaders[1],
        custom_html_body: row.html_full.to_s
      }
    rescue => e
      Rails.logger.warn("[digest-campaigns] aiwrite find_by_source_topic_id failed for topic_id=#{topic_id}: #{e.class}: #{e.message}")
      nil
    end

    def self.ensure_campaign_for_aiwrite(aiwrite_row)
      row = aiwrite_row.is_a?(Hash) ? aiwrite_row.symbolize_keys : {}
      source_topic_id = row[:source_topic_id].to_i
      aiwrite_id = row[:id].to_i
      raise ArgumentError, "aiwrite source_topic_id missing" if source_topic_id <= 0
      raise ArgumentError, "aiwrite id missing" if aiwrite_id <= 0
      raise ArgumentError, "aiwrite custom_html_body missing" if row[:custom_html_body].to_s.strip.blank?

      campaign_key = hardsale_campaign_key(source_topic_id: source_topic_id, aiwrite_id: aiwrite_id)

      attrs = {
        selection_sql: EMPTY_SELECTION_SQL,
        enabled: true,
        topic_sets: [],
        custom_html_body: row[:custom_html_body].to_s,
        preheader_line_1: row[:preheader_line_1].to_s,
        preheader_line_2: row[:preheader_line_2].to_s,
        subject_line_1: row[:subject_line_1].to_s,
        subject_line_2: row[:subject_line_2].to_s,
        subject_line_3: row[:subject_line_3].to_s,
        send_at: nil,
        last_error: nil,
        last_populated_at: Time.zone.now
      }

      campaign = ::DigestCampaigns::Campaign.find_or_initialize_by(campaign_key: campaign_key)
      campaign.assign_attributes(attrs)
      campaign.save!

      { campaign: campaign, campaign_key: campaign_key }
    end

    def self.enqueue_user_for_campaign(user_id:, campaign_key:, not_before: nil)
      uid = user_id.to_i
      key = campaign_key.to_s.strip
      raise ArgumentError, "user_id missing" if uid <= 0
      raise ArgumentError, "campaign_key missing" if key.blank?

      existing =
        DB.query(<<~SQL, campaign_key: key, user_id: uid).first
          SELECT id, status, not_before, sent_at
          FROM #{::DigestCampaigns::QUEUE_TABLE}
          WHERE campaign_key = :campaign_key
            AND user_id = :user_id
          LIMIT 1
        SQL

      if existing.present?
        return {
          queue_id: existing.id.to_i,
          status: existing.status.to_s,
          action: "existing",
          replaced_regular_digest: !%w[failed skipped_unsubscribed].include?(existing.status.to_s)
        }
      end

      row =
        DB.query(<<~SQL, campaign_key: key, user_id: uid, not_before: not_before).first
          INSERT INTO #{::DigestCampaigns::QUEUE_TABLE}
            (campaign_key, user_id, chosen_topic_ids, not_before, status, attempts, created_at, updated_at)
          VALUES
            (:campaign_key, :user_id, '{}'::int[], :not_before, 'queued', 0, NOW(), NOW())
          RETURNING id, status
        SQL

      {
        queue_id: row&.id.to_i,
        status: row&.status.to_s.presence || "queued",
        action: "inserted",
        replaced_regular_digest: true
      }
    rescue => e
      Rails.logger.warn("[digest-campaigns] enqueue_user_for_campaign failed campaign_key=#{key.inspect} user_id=#{uid}: #{e.class}: #{e.message}")
      { error: e.message, replaced_regular_digest: false }
    end

    def self.replace_push_digest_with_aiwrite_campaign(user:, source_topic_id:, not_before: nil)
      return { ok: false, reason: "user_missing" } if user.nil?

      aiwrite = find_by_source_topic_id(source_topic_id)
      return { ok: false, reason: "aiwrite_not_found" } if aiwrite.blank?

      ensured = ensure_campaign_for_aiwrite(aiwrite)
      enqueue = enqueue_user_for_campaign(
        user_id: user.id,
        campaign_key: ensured[:campaign_key],
        not_before: not_before
      )

      if enqueue[:replaced_regular_digest]
        {
          ok: true,
          aiwrite_id: aiwrite[:id],
          source_topic_id: aiwrite[:source_topic_id],
          campaign_id: ensured[:campaign].id,
          campaign_key: ensured[:campaign_key],
          queue_id: enqueue[:queue_id],
          queue_status: enqueue[:status],
          queue_action: enqueue[:action],
          preheader_line_1: aiwrite[:preheader_line_1],
          preheader_line_2: aiwrite[:preheader_line_2]
        }
      else
        {
          ok: false,
          reason: enqueue[:error].presence || "queue_not_replaced",
          aiwrite_id: aiwrite[:id],
          source_topic_id: aiwrite[:source_topic_id],
          campaign_id: ensured[:campaign].id,
          campaign_key: ensured[:campaign_key]
        }
      end
    rescue => e
      Rails.logger.warn("[digest-campaigns] replace_push_digest_with_aiwrite_campaign failed source_topic_id=#{source_topic_id}: #{e.class}: #{e.message}")
      { ok: false, reason: e.message }
    end

    def self.hardsale_campaign_key(source_topic_id:, aiwrite_id:)
      "hardsale_topic_#{source_topic_id.to_i}_aiwrite_#{aiwrite_id.to_i}"
    end

    def self.parse_json_string_array(raw)
      return [] if raw.blank?

      parsed = JSON.parse(raw)
      return [] unless parsed.is_a?(Array)

      parsed.map { |v| v.to_s.strip }.reject(&:blank?)
    rescue JSON::ParserError
      [raw.to_s.strip].reject(&:blank?)
    end

    def self.normalize_fixed_length_array(values, target_len)
      arr = Array(values).map { |v| v.to_s.strip }.reject(&:blank?).first(target_len)
      arr << "" while arr.length < target_len
      arr
    end
  end
end

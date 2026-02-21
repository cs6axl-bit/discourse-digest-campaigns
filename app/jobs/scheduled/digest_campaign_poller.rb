# frozen_string_literal: true

module Jobs
  class DigestCampaignPoller < ::Jobs::Scheduled
    every 1.minute
    sidekiq_options queue: "digest_campaigns"

    def execute(_args)
      return unless SiteSetting.digest_campaigns_enabled

      every_n = SiteSetting.digest_campaigns_poller_every_minutes.to_i
      every_n = 1 if every_n <= 0
      bucket = ::DigestCampaigns.minute_bucket_key
      return if (bucket % every_n) != 0

      only_key = SiteSetting.digest_campaigns_only_campaign_key.to_s.strip
      stale_minutes = SiteSetting.digest_campaigns_processing_stale_minutes.to_i
      claim_rows = SiteSetting.digest_campaigns_claim_rows_per_run.to_i
      chunk_size = SiteSetting.digest_campaigns_batch_chunk_size.to_i
      chunk_size = 25 if chunk_size <= 0

      requeue_stale(stale_minutes, only_key)

      ids = claim_row_ids_due(claim_rows, only_key)
      return if ids.empty?

      ids.each_slice(chunk_size) do |slice|
        Jobs.enqueue(:digest_campaign_send_batch, queue_ids: slice)
      end
    end

    private

    def requeue_stale(stale_minutes, only_key)
      return if stale_minutes <= 0

      where_key_sql = ""
      params = { stale_before: Time.zone.now - stale_minutes.minutes }

      if only_key.present?
        where_key_sql = " AND campaign_key = :campaign_key"
        params[:campaign_key] = only_key
      end

      # DB.exec is fine here (we only need rowcount)
      DB.exec(<<~SQL, params)
        UPDATE #{::DigestCampaigns::QUEUE_TABLE}
        SET status = 'queued',
            locked_at = NULL,
            updated_at = NOW(),
            last_error = COALESCE(last_error, '') || CASE
              WHEN COALESCE(last_error, '') = '' THEN 'Re-queued stale processing row'
              ELSE E'\nRe-queued stale processing row'
            END
        WHERE status = 'processing'
          AND locked_at IS NOT NULL
          AND locked_at < :stale_before
          #{where_key_sql}
      SQL
    end

    def claim_row_ids_due(limit, only_key)
      limit = 1 if limit.to_i <= 0

      where_key_sql = ""
      params = { limit: limit.to_i, now: Time.zone.now }

      if only_key.present?
        where_key_sql = " AND campaign_key = :campaign_key"
        params[:campaign_key] = only_key
      end

      # IMPORTANT:
      # In your Discourse/MiniSql build, DB.exec returns an Integer (rows affected),
      # so for RETURNING queries we must use DB.query to get rows.
      DB.query(<<~SQL, params).map { |r| r.id.to_i }
        WITH picked AS (
          SELECT id
          FROM #{::DigestCampaigns::QUEUE_TABLE}
          WHERE status = 'queued'
            AND (not_before IS NULL OR not_before <= :now)
          #{where_key_sql}
          ORDER BY id
          LIMIT :limit
          FOR UPDATE SKIP LOCKED
        )
        UPDATE #{::DigestCampaigns::QUEUE_TABLE} q
        SET status = 'processing',
            locked_at = NOW(),
            attempts = q.attempts + 1,
            updated_at = NOW()
        FROM picked
        WHERE q.id = picked.id
        RETURNING q.id AS id
      SQL
    end
  end
end

# frozen_string_literal: true

module Jobs
  class DigestCampaignSendBatch < ::Jobs::Base
    sidekiq_options queue: "digest_campaigns"

    def execute(args)
      return unless SiteSetting.digest_campaigns_enabled

      queue_ids = Array(args[:queue_ids]).map(&:to_i).select { |x| x > 0 }
      return if queue_ids.empty?

      target_per_min = SiteSetting.digest_campaigns_target_per_minute.to_i
      target_per_min = 1 if target_per_min <= 0

      bucket = ::DigestCampaigns.minute_bucket_key
      rate_key = ::DigestCampaigns.redis_rate_key(bucket)
      Discourse.redis.expire(rate_key, 120)

      queue_ids.each_with_index do |qid, idx|
        sent_this_min = Discourse.redis.get(rate_key).to_i
        if sent_this_min >= target_per_min
          remaining = queue_ids[idx..-1]
          requeue_rows(remaining, "Throttled: hit #{target_per_min}/min")
          return
        end

        row = DB.query_single(<<~SQL, id: qid)
          SELECT id, campaign_key, user_id, chosen_topic_ids, status
          FROM #{::DigestCampaigns::QUEUE_TABLE}
          WHERE id = :id
          LIMIT 1
        SQL
        next if row.blank?

        id, campaign_key, user_id, chosen_topic_ids, status = row
        next unless status == "processing"

        user = User.find_by(id: user_id)
        if user.nil?
          mark_failed(id, "User not found (user_id=#{user_id})")
          next
        end

        if SiteSetting.digest_campaigns_respect_digest_unsubscribe && digest_unsubscribed?(user)
          mark_skipped_unsubscribed(id)
          next
        end

        campaign = DigestCampaigns::Campaign.find_by(campaign_key: campaign_key.to_s)
        if campaign.nil?
          mark_failed(id, "Campaign not found (campaign_key=#{campaign_key})")
          next
        end

        chosen_topic_ids = Array(chosen_topic_ids).map(&:to_i)
        if chosen_topic_ids.blank?
          picked = ::DigestCampaigns.pick_random_topic_set(campaign.topic_sets)
          if picked.blank?
            mark_failed(id, "Campaign has no topic sets configured")
            next
          end

          DB.exec(<<~SQL, id: id, arr: picked)
            UPDATE #{::DigestCampaigns::QUEUE_TABLE}
            SET chosen_topic_ids = :arr,
                updated_at = NOW()
            WHERE id = :id
              AND status = 'processing'
          SQL

          chosen_topic_ids = picked
        end

        begin
          message =
            UserNotifications.digest_campaign(
              user,
              topic_ids: chosen_topic_ids,
              campaign_key: campaign_key.to_s,
              since: campaign.send_at
            )

          # Use :digest type so your digest-specific plugins & routing logic can match
          Email::Sender.new(message, :digest).send
          Discourse.redis.incr(rate_key)

          DB.exec(<<~SQL, id: id)
            UPDATE #{::DigestCampaigns::QUEUE_TABLE}
            SET status = 'sent',
                sent_at = NOW(),
                locked_at = NULL,
                updated_at = NOW(),
                last_error = NULL
            WHERE id = :id
          SQL
        rescue => e
          mark_failed(id, "#{e.class}: #{e.message}")
        end
      end
    end

    private

    def digest_unsubscribed?(user)
      opt = user.user_option
      return false if opt.nil?
      opt.email_digests == false
    rescue
      false
    end

    def mark_skipped_unsubscribed(id)
      DB.exec(<<~SQL, id: id)
        UPDATE #{::DigestCampaigns::QUEUE_TABLE}
        SET status = 'skipped_unsubscribed',
            locked_at = NULL,
            updated_at = NOW(),
            last_error = NULL
        WHERE id = :id
      SQL
    end

    def requeue_rows(ids, note)
      return if ids.blank?

      DB.exec(<<~SQL, ids: ids, note: note.to_s)
        UPDATE #{::DigestCampaigns::QUEUE_TABLE}
        SET status = 'queued',
            locked_at = NULL,
            updated_at = NOW(),
            last_error = COALESCE(last_error, '') || CASE
              WHEN COALESCE(last_error, '') = '' THEN :note
              ELSE E'\n' || :note
            END
        WHERE id = ANY(:ids)
          AND status = 'processing'
      SQL
    end

    def mark_failed(id, err)
      DB.exec(<<~SQL, id: id, err: err.to_s)
        UPDATE #{::DigestCampaigns::QUEUE_TABLE}
        SET status = 'failed',
            locked_at = NULL,
            updated_at = NOW(),
            last_error = :err
        WHERE id = :id
      SQL
    end
  end
end

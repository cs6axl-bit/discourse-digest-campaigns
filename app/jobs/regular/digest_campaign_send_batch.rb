# frozen_string_literal: true

module Jobs
  class DigestCampaignSendBatch < ::Jobs::Base
    def execute(args)
      return unless SiteSetting.digest_campaigns_enabled

      campaign_key = args[:campaign_key].to_s
      ids = Array(args[:queue_ids]).map(&:to_i).select { |x| x > 0 }.uniq
      return if campaign_key.blank? || ids.blank?

      # per-minute throttle
      bucket = ::DigestCampaigns.minute_bucket_key
      rate_key = ::DigestCampaigns.redis_rate_key(bucket)
      max_per_min = SiteSetting.digest_campaigns_max_per_minute.to_i
      max_per_min = 300 if max_per_min <= 0

      sent_this_min = Discourse.redis.get(rate_key).to_i
      remaining = max_per_min - sent_this_min
      return if remaining <= 0

      ids = ids.first(remaining)

      rows =
        DB.query(<<~SQL, ids: ids, key: campaign_key)
          SELECT id, user_id, chosen_topic_ids
          FROM #{::DigestCampaigns::QUEUE_TABLE}
          WHERE id IN (:ids)
            AND campaign_key = :key
            AND status = 'processing'
          ORDER BY id ASC
        SQL

      return if rows.blank?

      rows.each do |r|
        id = r.id.to_i
        user_id = r.user_id.to_i
        chosen_topic_ids = r.chosen_topic_ids

        begin
          user = User.find_by(id: user_id)
          if user.blank?
            DB.exec(<<~SQL, id: id)
              UPDATE #{::DigestCampaigns::QUEUE_TABLE}
              SET status='failed', last_error='user_not_found', updated_at=NOW()
              WHERE id=:id
            SQL
            next
          end

          # Optional: skip unsubscribed users
          if SiteSetting.digest_campaigns_skip_unsubscribed
            unsub = UnsubscribeKey.unsubscribe_key_exists?(user, UnsubscribeKey::DIGEST_TYPE) rescue false
            if unsub
              DB.exec(<<~SQL, id: id)
                UPDATE #{::DigestCampaigns::QUEUE_TABLE}
                SET status='skipped_unsubscribed', updated_at=NOW()
                WHERE id=:id AND status='processing'
              SQL
              next
            end
          end

          # If not chosen yet, choose once and store (so retries reuse)
          if chosen_topic_ids.blank?
            topic_sets =
              DB.query_single(<<~SQL, key: campaign_key)
                SELECT topic_sets
                FROM #{::DigestCampaigns::CAMPAIGNS_TABLE}
                WHERE key = :key
                LIMIT 1
              SQL

            picked = ::DigestCampaigns.pick_random_topic_set(topic_sets)
            picked = Array(picked).map(&:to_i).select { |x| x > 0 }.uniq

            arr_literal = "{#{picked.join(',')}}"

            DB.exec(<<~SQL, id: id, arr: arr_literal)
              UPDATE #{::DigestCampaigns::QUEUE_TABLE}
              SET chosen_topic_ids = :arr::int[],
                  updated_at = NOW()
              WHERE id = :id
                AND status = 'processing'
            SQL

            chosen_topic_ids = picked
          end

          # Build message via UserNotifications.digest so ALL digest plugins can wrap/modify it.
          message =
            UserNotifications.digest(
              user,
              campaign_topic_ids: Array(chosen_topic_ids).map(&:to_i),
              campaign_key: campaign_key,
              campaign_since: Time.zone.now
            )

          # Now actually send it (after plugins modified message)
          Email::Sender.new(message, :digest).send

          DB.exec(<<~SQL, id: id)
            UPDATE #{::DigestCampaigns::QUEUE_TABLE}
            SET status='sent', sent_at=NOW(), updated_at=NOW(), last_error=NULL
            WHERE id=:id AND status='processing'
          SQL

          Discourse.redis.incr(rate_key)
          Discourse.redis.expire(rate_key, 120)
        rescue => e
          DB.exec(<<~SQL, id: id, err: "#{e.class}: #{e.message}".truncate(500))
            UPDATE #{::DigestCampaigns::QUEUE_TABLE}
            SET status='failed', last_error=:err, attempts=COALESCE(attempts,0)+1, updated_at=NOW()
            WHERE id=:id
          SQL
          Rails.logger.warn("DigestCampaignSendBatch failed id=#{id} user_id=#{user_id} #{e.class}: #{e.message}")
        end
      end
    end
  end
end

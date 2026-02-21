# frozen_string_literal: true

module ::DigestCampaigns
  module UserNotificationsExtension
    # Called from the class override in plugin.rb:
    #   ::DigestCampaigns::UserNotificationsExtension.campaign_aware_digest(self, user, opts)
    #
    # IMPORTANT: This MUST RETURN an UNSENT Mail::Message.
    # Sending happens in the job AFTER all digest plugins have run.
    def self.campaign_aware_digest(notifier, user, opts = {})
      campaign_topic_ids = opts[:campaign_topic_ids]
      campaign_key = opts[:campaign_key]
      campaign_since = opts[:campaign_since]

      # Normal digests unaffected
      if campaign_topic_ids.blank?
        return notifier.digest_without_campaigns(user, opts)
      end

      notifier.build_summary_for(user)

      notifier.instance_variable_set(:@campaign_key, campaign_key.to_s)
      notifier.instance_variable_set(:@unsubscribe_key, UnsubscribeKey.create_key_for(notifier.instance_variable_get(:@user), UnsubscribeKey::DIGEST_TYPE))

      since =
        campaign_since.presence ||
        [user.last_seen_at, 1.month.ago].compact.max

      notifier.instance_variable_set(:@since, since)

      ids = Array(campaign_topic_ids).map(&:to_i).select { |x| x > 0 }.uniq

      topics = Topic.where(id: ids).includes(:category, :user, :first_post).to_a
      by_id = topics.index_by(&:id)
      topics_for_digest = ids.map { |id| by_id[id] }.compact

      popular_n = SiteSetting.digest_topics.to_i
      popular_n = 10 if popular_n <= 0

      popular_topics = topics_for_digest[0...popular_n] || []
      other_new_for_you =
        if topics_for_digest.size > popular_n
          topics_for_digest[popular_n..-1] || []
        else
          []
        end

      notifier.instance_variable_set(:@popular_topics, popular_topics)
      notifier.instance_variable_set(:@other_new_for_you, other_new_for_you)

      # Per-user random popular posts (24–72h old)
      popular_posts = ::DigestCampaigns.fetch_random_popular_posts(3)
      notifier.instance_variable_set(:@popular_posts, popular_posts)

      excerpts = {}
      popular_topics.each do |t|
        next if t&.first_post.blank?
        next if t.first_post.user_deleted
        excerpts[t.first_post.id] = notifier.email_excerpt(t.first_post.cooked, t.first_post)
      end
      popular_posts.each do |p|
        next if p.blank?
        next if p.user_deleted
        excerpts[p.id] = notifier.email_excerpt(p.cooked, p)
      end
      notifier.instance_variable_set(:@excerpts, excerpts)

      counts = [
        {
          id: "new_topics",
          label_key: "user_notifications.digest.new_topics",
          value: topics_for_digest.size,
          href: "#{Discourse.base_url}/new",
        },
      ]
      notifier.instance_variable_set(:@counts, counts)

      notifier.instance_variable_set(:@preheader_text, I18n.t("user_notifications.digest.preheader", since: since))

      # Build HTML using the standard digest template so other digest plugins that parse/modify HTML still work
      html_body =
        notifier.render_to_string(
          template: "user_notifications/digest",
          formats: [:html]
        )

      # Minimal text part (avoid translation-missing issues)
      text_lines = []
      text_lines << "#{SiteSetting.title} Summary"
      text_lines << ""
      text_lines << "Topics:"
      topics_for_digest.each do |t|
        text_lines << "- #{t.title} (#{Discourse.base_url_no_prefix}#{t.url})"
      end
      text_body = text_lines.join("\n")

      message =
        Email::MessageBuilder.new(
          to: user.email,
          template: "user_notifications/digest",
          locale: user.effective_locale,
          subject: Email::MessageBuilder.subject_for(
            user,
            "user_notifications.digest.subject_template",
            site_name: SiteSetting.title
          )
        ).build

      message.html_part.body = html_body
      message.text_part.body = text_body

      # DO NOT SEND HERE.
      # Return the message so other digest plugins (prepend wrappers) can still modify it.
      message
    end
  end
end

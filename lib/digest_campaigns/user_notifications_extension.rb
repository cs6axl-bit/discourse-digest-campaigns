# frozen_string_literal: true

module ::DigestCampaigns
  module UserNotificationsExtension
    # Sends a "real digest" email (Option A) but with topics you provide.
    #
    # Uses Discourse's built-in templates:
    #   app/views/user_notifications/digest.html.erb (+ partials)
    #
    # Important instance vars the template uses:
    #   @preheader_text, @counts, @popular_topics, @other_new_for_you,
    #   @popular_posts, @excerpts, @unsubscribe_key
    #
    def digest_campaign(user, topic_ids:, campaign_key:, since: nil)
      # This sets @user, @site_name, @email_prefix, locale, etc (same as core digest)
      build_summary_for(user)

      @campaign_key = campaign_key.to_s
      @unsubscribe_key = UnsubscribeKey.create_key_for(@user, UnsubscribeKey::DIGEST_TYPE)

      # used in the preheader + some stats logic
      @since = since.presence || [user.last_seen_at, 1.month.ago].compact.max

      ids = Array(topic_ids).map(&:to_i).select { |x| x > 0 }.uniq
      topics = Topic.where(id: ids).includes(:category, :user, :first_post).to_a
      by_id = topics.index_by(&:id)
      topics_for_digest = ids.map { |id| by_id[id] }.compact

      # Split like core digest does (first N = "popular", rest = "more new")
      popular_n = SiteSetting.digest_topics.to_i
      popular_n = 0 if popular_n < 0

      @popular_topics = topics_for_digest[0, popular_n] || []
      @other_new_for_you =
        if topics_for_digest.size > popular_n
          topics_for_digest[popular_n..-1] || []
        else
          []
        end

      # Campaign rule: "no filtering of provided topics, send as is"
      # => Do NOT include extra "popular posts" from elsewhere
      @popular_posts = []

      # Excerpts for the popular topic cards (template expects @excerpts[first_post_id])
      @excerpts = {}
      @popular_topics.each do |t|
        next if t&.first_post.blank?
        next if t.first_post.user_deleted
        @excerpts[t.first_post.id] = email_excerpt(t.first_post.cooked, t.first_post)
      end

      # Stats row at top (template expects @counts)
      new_topics_count = topics_for_digest.size
      @counts = [
        {
          id: "new_topics",
          label_key: "user_notifications.digest.new_topics",
          value: new_topics_count,
          href: "#{Discourse.base_url}/new",
        },
      ]

      value = user.unread_notifications + user.unread_high_priority_notifications
      if value > 0
        @counts << {
          id: "unread_notifications",
          label_key: "user_notifications.digest.unread_notifications",
          value: value,
          href: "#{Discourse.base_url}/my/notifications",
        }
      end

      if @counts.size < 3
        value = user.unread_notifications_of_type(Notification.types[:liked], since: @since)
        if value > 0
          @counts << {
            id: "likes_received",
            label_key: "user_notifications.digest.liked_received",
            value: value,
            href: "#{Discourse.base_url}/my/notifications",
          }
        end
      end

      if @counts.size < 3 && user.user_option.digest_after_minutes.to_i >= 1440
        value = summary_new_users_count(@since)
        if value > 0
          @counts << {
            id: "new_users",
            label_key: "user_notifications.digest.new_users",
            value: value,
            href: "#{Discourse.base_url}/about",
          }
        end
      end

      @preheader_text = I18n.t("user_notifications.digest.preheader", since: @since)

      # Subject: keep your campaign prefix, but still use digest mailer+template
      prefix = SiteSetting.digest_campaigns_subject_prefix.to_s.strip
      base_subject =
        I18n.t(
          "user_notifications.digest.subject_template",
          email_prefix: @email_prefix,
          date: short_date(Time.now),
        )

      subject =
        if prefix.present?
          "#{prefix} #{@campaign_key}".strip
        else
          "#{base_subject} #{@campaign_key}".strip
        end

      build_email(
        user.email,
        template: "user_notifications/digest",
        from_alias: I18n.t("user_notifications.digest.from", site_name: Email.site_title),
        subject: subject,
        add_unsubscribe_link: true,
        unsubscribe_url: "#{Discourse.base_url}/email/unsubscribe/#{@unsubscribe_key}",
        topic_ids: topics_for_digest.map(&:id),
        post_ids: topics_for_digest.map { |t| t.first_post&.id }.compact,
      )
    end
  end
end

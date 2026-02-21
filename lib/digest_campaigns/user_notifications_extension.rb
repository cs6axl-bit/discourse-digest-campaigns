# frozen_string_literal: true

module ::DigestCampaigns
  module UserNotificationsExtension
    # Option A: render the REAL Discourse digest template, but with provided topic_ids.
    #
    # Critical details:
    # - Use DOT template name: "user_notifications.digest"
    # - Use DOT i18n keys: "user_notifications.digest.*"
    def digest_campaign(user, topic_ids:, campaign_key:, since: nil)
      build_summary_for(user)

      @campaign_key = campaign_key.to_s
      @unsubscribe_key = UnsubscribeKey.create_key_for(@user, UnsubscribeKey::DIGEST_TYPE)
      @since = since.presence || [user.last_seen_at, 1.month.ago].compact.max

      ids = Array(topic_ids).map(&:to_i).select { |x| x > 0 }.uniq
      topics = Topic.where(id: ids).includes(:category, :user, :first_post).to_a
      by_id = topics.index_by(&:id)
      topics_for_digest = ids.map { |id| by_id[id] }.compact

      popular_n = SiteSetting.digest_topics.to_i
      popular_n = 0 if popular_n < 0

      @popular_topics = topics_for_digest[0, popular_n] || []
      @other_new_for_you =
        if topics_for_digest.size > popular_n
          topics_for_digest[popular_n..-1] || []
        else
          []
        end

      # Campaigns: do not add extra content
      @popular_posts = []

      # Excerpts for topic cards (used by digest template)
      @excerpts = {}
      @popular_topics.each do |t|
        next if t&.first_post.blank?
        next if t.first_post.user_deleted
        @excerpts[t.first_post.id] = email_excerpt(t.first_post.cooked, t.first_post)
      end

      # Minimal counts row; uses DOT label keys
      @counts = [
        {
          id: "new_topics",
          label_key: "user_notifications.digest.new_topics",
          value: topics_for_digest.size,
          href: "#{Discourse.base_url}/new",
        },
      ]

      @preheader_text = I18n.t("user_notifications.digest.preheader", since: @since)

      # IMPORTANT: DOT subject key (not slash)
      base_subject =
        I18n.t(
          "user_notifications.digest.subject_template",
          email_prefix: @email_prefix,
          date: short_date(Time.now)
        )

      prefix = SiteSetting.digest_campaigns_subject_prefix.to_s.strip
      prefix = "[Campaign Digest]" if prefix.blank?

      subject = "#{prefix} - #{base_subject} - #{@campaign_key}".strip

      # IMPORTANT: DOT template name (not "user_notifications/digest")
      build_email(
        user.email,
        template: "user_notifications.digest",
        from_alias: I18n.t("user_notifications.digest.from", site_name: Email.site_title),
        subject: subject,
        add_unsubscribe_link: true,
        unsubscribe_url: "#{Discourse.base_url}/email/unsubscribe/#{@unsubscribe_key}",
        topic_ids: topics_for_digest.map(&:id),
        post_ids: topics_for_digest.map { |t| t.first_post&.id }.compact
      )
    end
  end
end

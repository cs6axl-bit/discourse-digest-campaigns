# frozen_string_literal: true

module ::DigestCampaigns
  module UserNotificationsExtension
    # Builds a "real digest" HTML using core template, but avoids missing text i18n key
    # by providing our own plain text body.
    def digest_campaign(user, topic_ids:, campaign_key:, since: nil)
      build_summary_for(user)

      @campaign_key = campaign_key.to_s
      @unsubscribe_key = UnsubscribeKey.create_key_for(@user, UnsubscribeKey::DIGEST_TYPE)
      @since = since.presence || [user.last_seen_at, 1.month.ago].compact.max

      ids = Array(topic_ids).map(&:to_i).select { |x| x > 0 }.uniq
      topics = Topic.where(id: ids).includes(:category, :user, :first_post).to_a
      by_id = topics.index_by(&:id)
      topics_for_digest = ids.map { |id| by_id[id] }.compact

      # Make sure at least 1 topic appears in the "popular topics" block if any exist
      popular_n = SiteSetting.digest_topics.to_i
      popular_n = 0 if popular_n < 0
      popular_n = 1 if popular_n == 0 && topics_for_digest.present?

      @popular_topics = topics_for_digest[0, popular_n] || []
      @other_new_for_you =
        if topics_for_digest.size > popular_n
          topics_for_digest[popular_n..-1] || []
        else
          []
        end

      # Campaign rule: do not add extra "popular posts"
      @popular_posts = []

      # Excerpts used by digest template for topic cards
      @excerpts = {}
      @popular_topics.each do |t|
        next if t&.first_post.blank?
        next if t.first_post.user_deleted
        @excerpts[t.first_post.id] = email_excerpt(t.first_post.cooked, t.first_post)
      end

      # Minimal counts row
      @counts = [
        {
          id: "new_topics",
          label_key: "user_notifications.digest.new_topics",
          value: topics_for_digest.size,
          href: "#{Discourse.base_url}/new",
        },
      ]

      @preheader_text = I18n.t("user_notifications.digest.preheader", since: @since)

      # --------
      # SUBJECT: force to first topic title (so you never see "Summary" when topics exist)
      # --------
      if topics_for_digest.first
        prefix = @email_prefix.to_s.strip
        subject = "#{prefix} #{topics_for_digest.first.title}".strip
      else
        # fallback to core digest subject (dot key)
        subject =
          I18n.t(
            "user_notifications.digest.subject_template",
            email_prefix: @email_prefix,
            date: short_date(Time.now)
          )
      end

      # --------
      # HTML: render the real digest HTML template (filesystem path uses slash)
      # --------
      html = render_to_string(template: "user_notifications/digest", formats: [:html])

      # --------
      # TEXT: custom plain-text body (avoids missing user_notifications.digest.text_body_template)
      # --------
      lines = []
      lines << "Activity Summary"
      lines << "Campaign: #{@campaign_key}" if @campaign_key.present?
      lines << ""
      if topics_for_digest.empty?
        lines << "(No topics)"
      else
        lines << "Topics:"
        topics_for_digest.each_with_index do |t, i|
          lines << "#{i + 1}. #{t.title} - #{Discourse.base_url}/t/#{t.slug}/#{t.id}"
        end
      end
      lines << ""
      lines << "Unsubscribe: #{Discourse.base_url}/email/unsubscribe/#{@unsubscribe_key}"
      text_body = lines.join("\n")

      # IMPORTANT:
      # - do NOT pass `template:` here (that triggers the missing text_body_template key on your build)
      # - pass html_override + body explicitly
      build_email(
        user.email,
        subject: subject,
        body: text_body,
        html_override: html,
        add_unsubscribe_link: true,
        unsubscribe_url: "#{Discourse.base_url}/email/unsubscribe/#{@unsubscribe_key}",
        topic_ids: topics_for_digest.map(&:id),
        post_ids: topics_for_digest.map { |t| t.first_post&.id }.compact
      )
    end
  end
end

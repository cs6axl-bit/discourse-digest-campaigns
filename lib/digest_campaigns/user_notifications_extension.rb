# frozen_string_literal: true

module ::DigestCampaigns
  module UserNotificationsExtension
    def digest(user, opts = {})
      campaign_topic_ids = opts[:campaign_topic_ids]
      campaign_key = opts[:campaign_key]
      campaign_since = opts[:campaign_since]

      if campaign_topic_ids.blank?
        return digest_without_campaigns(user, opts)
      end

      build_summary_for(user)

      @campaign_key = campaign_key.to_s
      @unsubscribe_key = UnsubscribeKey.create_key_for(@user, UnsubscribeKey::DIGEST_TYPE)
      @since = campaign_since.presence || [user.last_seen_at, 1.month.ago].compact.max

      ids = Array(campaign_topic_ids).map(&:to_i).select { |x| x > 0 }.uniq
      topics = Topic.where(id: ids).includes(:category, :user, :first_post).to_a
      by_id = topics.index_by(&:id)
      topics_for_digest = ids.map { |id| by_id[id] }.compact

      popular_n = SiteSetting.digest_topics.to_i
      popular_n = 10 if popular_n <= 0
      @popular_topics = topics_for_digest[0...popular_n] || []
      @other_new_for_you = topics_for_digest.size > popular_n ? (topics_for_digest[popular_n..-1] || []) : []

      # Campaign: 3 random forum posts created 24–72 hours ago
      @popular_posts = ::DigestCampaigns.fetch_random_popular_posts(3)

      # excerpts for template
      @excerpts = {}
      @popular_topics.each do |t|
        next if t&.first_post.blank?
        next if t.first_post.user_deleted
        @excerpts[t.first_post.id] = email_excerpt(t.first_post.cooked, t.first_post)
      end
      @popular_posts.each do |p|
        next if p.blank?
        next if p.user_deleted
        @excerpts[p.id] = email_excerpt(p.cooked, p)
      end

      @counts = [
        {
          id: "new_topics",
          label_key: "user_notifications.digest.new_topics",
          value: topics_for_digest.size,
          href: "#{Discourse.base_url}/new",
        },
      ]

      # =========================
      # SUBJECT + PREHEADER OVERRIDES
      # =========================
      first_topic = topics_for_digest.first
      first_post = first_topic&.first_post

      # Subject = first topic title (fallback to old campaign subject if no topics)
      base_subject = I18n.t(
        "user_notifications.digest.subject_template",
        site_name: SiteSetting.title,
        date: short_date(Time.now)
      )
      prefix = SiteSetting.digest_campaigns_subject_prefix.to_s.strip
      prefix = "[Campaign Digest]" if prefix.blank?
      fallback_subject = "#{prefix} - #{base_subject} - #{@campaign_key}".strip

      subject = first_topic&.title.to_s.strip
      subject = fallback_subject if subject.blank?

      # Preheader/subheader = first 100 chars of first topic body (plain text)
      preheader = ""
      if first_post.present? && first_post.cooked.present?
        begin
          plain = PrettyText.excerpt(first_post.cooked, 300, strip_links: true, keep_emoji_images: false).to_s
          plain = plain.gsub(/\s+/, " ").strip
          preheader = plain[0, 100].to_s.strip
        rescue
          preheader = ""
        end
      end
      @preheader_text = preheader.present? ? preheader : I18n.t("user_notifications.digest.preheader", since: @since)

      # Render digest HTML
      html = render_to_string(template: "user_notifications/digest", formats: [:html])

      # Plain text body
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

      email_id = ::DigestCampaigns::CampaignPostprocess.generate_email_id

      msg = build_email(
        user.email,
        subject: subject,
        body: text_body,
        html_override: html,
        add_unsubscribe_link: true,
        unsubscribe_url: "#{Discourse.base_url}/email/unsubscribe/#{@unsubscribe_key}",
        topic_ids: topics_for_digest.map(&:id),
        post_ids: topics_for_digest.map { |t| t.first_post&.id }.compact
      )

      ::DigestCampaigns::CampaignPostprocess.process!(msg, user, email_id)

      msg
    end
  end
end

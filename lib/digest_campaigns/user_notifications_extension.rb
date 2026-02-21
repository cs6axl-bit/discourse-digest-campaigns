# frozen_string_literal: true

module ::DigestCampaigns
  module UserNotificationsExtension
    # We override UserNotifications#digest to support campaign overrides while keeping normal digest behavior intact.
    #
    # Call with:
    #   UserNotifications.digest(user,
    #     campaign_topic_ids: [1,2,3],
    #     campaign_key: "blast_x",
    #     campaign_since: Time.zone.now
    #   )
    #
    # If campaign_topic_ids is NOT present, we delegate to the original digest method.
    def digest(user, opts = {})
      campaign_topic_ids = opts[:campaign_topic_ids]
      campaign_key = opts[:campaign_key]
      campaign_since = opts[:campaign_since]

      # Normal digests unaffected
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

      # Keep the digest layout: split chosen topics into popular + other
      popular_n = SiteSetting.digest_topics.to_i
      popular_n = 10 if popular_n <= 0
      @popular_topics = topics_for_digest[0...popular_n] || []
      @other_new_for_you = topics_for_digest.size > popular_n ? (topics_for_digest[popular_n..-1] || []) : []

      # Campaign: pick 3 random forum posts created 24–72 hours ago
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

      @preheader_text = I18n.t("user_notifications.digest.preheader", since: @since)

      # Standard digest subject base (we keep your campaign prefix + campaign_key behavior)
      base_subject = I18n.t(
        "user_notifications.digest.subject_template",
        site_name: SiteSetting.title,
        date: short_date(Time.now)
      )

      prefix = SiteSetting.digest_campaigns_subject_prefix.to_s.strip
      prefix = "[Campaign Digest]" if prefix.blank?
      subject = "#{prefix} - #{base_subject} - #{@campaign_key}".strip

      # Render the real digest HTML template (this is what your digest HTML plugins target)
      html = render_to_string(template: "user_notifications/digest", formats: [:html])

      # Plain text body (avoid missing text_body_template on your build)
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

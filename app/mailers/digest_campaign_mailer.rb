# frozen_string_literal: true

class DigestCampaignMailer < ActionMailer::Base
  # Same includes/layout as core UserNotifications digest
  include UserNotificationsHelper
  include ApplicationHelper
  helper :application, :email
  default charset: "UTF-8"
  layout "email_template"
  include Email::BuildEmailHelper

  # Sends a REAL Discourse digest-looking email, but with provided topic_ids (in order).
  #
  # - Uses the core template: user_notifications/digest
  # - Uses digest-type unsubscribe (same as real digests)
  # - Builds @popular_topics / @other_new_for_you / @excerpts etc like core expects
  def campaign_digest(user, topic_ids, campaign_key)
    build_summary_for(user)

    @campaign_key = campaign_key.to_s

    # Digest-style unsubscribe (the same one core uses)
    @unsubscribe_key = UnsubscribeKey.create_key_for(@user, UnsubscribeKey::DIGEST_TYPE)

    # For display in the digest template (preheader + "since")
    # You can change this to something else; it's mostly cosmetic.
    @since = 1.month.ago

    ids = Array(topic_ids).map(&:to_i).select { |x| x > 0 }.uniq
    topics = Topic.where(id: ids).includes(:first_post).to_a

    # Preserve the caller's order
    index = {}
    ids.each_with_index { |id, i| index[id] = i }
    topics.sort_by! { |t| index[t.id] || 999_999 }

    # Split into the same sections the digest template expects
    digest_top_n = SiteSetting.digest_topics.to_i
    digest_top_n = 0 if digest_top_n < 0

    @popular_topics = digest_top_n > 0 ? topics.first(digest_top_n) : topics
    @other_new_for_you = if digest_top_n > 0 && topics.size > digest_top_n
      topics[digest_top_n..-1]
    else
      []
    end

    # Core template expects this variable to exist
    @popular_posts = []

    # Excerpts for popular topics (core uses first post excerpt)
    @excerpts = {}
    @popular_topics.each do |t|
      next if t.first_post.blank?
      @excerpts[t.first_post.id] = email_excerpt(t.first_post.cooked, t.first_post)
    end

    # Stats row at top of digest template
    # Keep it minimal and safe
    @counts = [
      {
        id: "new_topics",
        label_key: "user_notifications.digest.new_topics",
        value: topics.size,
        href: "#{Discourse.base_url}/latest",
      },
    ]

    # Preheader text (same key core uses)
    @preheader_text = I18n.t("user_notifications.digest.preheader", since: @since)

    # Subject: keep the exact digest-style subject formatting
    prefix = SiteSetting.digest_campaigns_subject_prefix.to_s.strip
    prefix = "[Campaign Digest]" if prefix.blank?

    subject = "#{prefix} - " + I18n.t(
      "user_notifications.digest.subject_template",
      email_prefix: @email_prefix,
      date: short_date(Time.now),
    )

    # Tracking fields (same names core digest sets)
    topic_ids_for_tracking = topics.map(&:id)
    post_ids_for_tracking =
      Post.where(topic_id: topic_ids_for_tracking, post_number: 1).pluck(:id)

    opts = {
      template: "user_notifications.digest", # <-- THIS is the key: use core digest template
      from_alias: I18n.t("user_notifications.digest.from", site_name: Email.site_title),
      subject: subject,
      add_unsubscribe_link: true,
      unsubscribe_url: "#{Discourse.base_url}/email/unsubscribe/#{@unsubscribe_key}",
      topic_ids: topic_ids_for_tracking,
      post_ids: post_ids_for_tracking,
    }

    build_email(@user.email, opts)
  end

  private

  # Copied from core UserNotifications (needed for digest layout variables)
  def build_summary_for(user)
    @site_name = SiteSetting.email_prefix.presence || SiteSetting.title
    @user = user
    @date = short_date(Time.now)
    @base_url = Discourse.base_url
    @email_prefix = SiteSetting.email_prefix.presence || SiteSetting.title
    @header_color = ColorScheme.hex_for_name("header_primary")
    @header_bgcolor = ColorScheme.hex_for_name("header_background")
    @anchor_color = ColorScheme.hex_for_name("tertiary")
    @markdown_linker = MarkdownLinker.new(@base_url)
    @disable_email_custom_styles = !SiteSetting.apply_custom_styles_to_digest
  end
end

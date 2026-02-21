# frozen_string_literal: true

class DigestCampaignMailer < ActionMailer::Base
  include Email::BuildEmailHelper
  layout "email"

  def campaign_digest(user, topic_ids, campaign_key)
    @user = user
    @campaign_key = campaign_key.to_s
    @topic_ids = Array(topic_ids).map(&:to_i)

    # Regular digest unsubscribe key/link
    @unsubscribe_key = UnsubscribeKey.create_key_for(@user, UnsubscribeKey::DIGEST_TYPE)
    @unsubscribe_url = "#{Discourse.base_url}/email/unsubscribe/#{@unsubscribe_key}"

    # No filtering; just resolve title/slug when possible
    topics = Topic.where(id: @topic_ids).pluck(:id, :title, :slug)
    @topic_map = {}
    topics.each do |id, title, slug|
      @topic_map[id.to_i] = { title: title.to_s, slug: slug.to_s }
    end

    prefix = SiteSetting.digest_campaigns_subject_prefix.to_s.strip
    prefix = "[Campaign Digest]" if prefix.blank?
    subject = "#{prefix} #{@campaign_key}".strip

    text_body = render_to_string(
      template: "digest_campaign_mailer/campaign_digest",
      formats: [:text]
    )

    html_override = render_to_string(
      template: "digest_campaign_mailer/campaign_digest",
      formats: [:html]
    )

    build_email(
      @user.email,
      subject: subject,
      body: text_body,
      html_override: html_override,
      add_unsubscribe_link: true,
      unsubscribe_url: @unsubscribe_url,
      include_respond_instructions: false
    )
  end

  private

  def topic_url(topic_id, slug)
    Discourse.base_url + "/t/#{slug}/#{topic_id}"
  end
  helper_method :topic_url
end

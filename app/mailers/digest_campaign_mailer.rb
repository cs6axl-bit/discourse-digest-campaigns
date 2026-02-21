# frozen_string_literal: true

class DigestCampaignMailer < ActionMailer::Base
  layout "email"

  def campaign_digest(user, topic_ids, campaign_key)
    @user = user
    @campaign_key = campaign_key.to_s
    @topic_ids = Array(topic_ids).map(&:to_i)

    # No filtering; just resolve title/slug when possible
    topics = Topic.where(id: @topic_ids).pluck(:id, :title, :slug)
    @topic_map = {}
    topics.each do |id, title, slug|
      @topic_map[id.to_i] = { title: title.to_s, slug: slug.to_s }
    end

    prefix = SiteSetting.digest_campaigns_subject_prefix.to_s.strip
    prefix = "[Campaign Digest]" if prefix.blank?
    subject = "#{prefix} #{@campaign_key}".strip

    message = Email::MessageBuilder.new(to: @user.email, subject: subject).build

    message.html_part = Mail::Part.new do
      content_type "text/html; charset=UTF-8"
      body render_to_string(template: "digest_campaign_mailer/campaign_digest", formats: [:html])
    end

    message.text_part = Mail::Part.new do
      body render_to_string(template: "digest_campaign_mailer/campaign_digest", formats: [:text])
    end

    Email::Sender.new(message, :campaign_digest).send
  end

  private

  def topic_url(topic_id, slug)
    Discourse.base_url + "/t/#{slug}/#{topic_id}"
  end
  helper_method :topic_url
end

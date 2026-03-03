# frozen_string_literal: true

class AddHtmlCampaignFieldsToDigestCampaigns < ActiveRecord::Migration[7.0]
  def up
    return unless table_exists?(:digest_campaigns)

    add_column :digest_campaigns, :custom_html_body, :text unless column_exists?(:digest_campaigns, :custom_html_body)
    add_column :digest_campaigns, :preheader_line_1, :text unless column_exists?(:digest_campaigns, :preheader_line_1)
    add_column :digest_campaigns, :preheader_line_2, :text unless column_exists?(:digest_campaigns, :preheader_line_2)

    add_column :digest_campaigns, :subject_line_1, :text unless column_exists?(:digest_campaigns, :subject_line_1)
    add_column :digest_campaigns, :subject_line_2, :text unless column_exists?(:digest_campaigns, :subject_line_2)
    add_column :digest_campaigns, :subject_line_3, :text unless column_exists?(:digest_campaigns, :subject_line_3)
  end

  def down
    return unless table_exists?(:digest_campaigns)

    remove_column :digest_campaigns, :custom_html_body if column_exists?(:digest_campaigns, :custom_html_body)
    remove_column :digest_campaigns, :preheader_line_1 if column_exists?(:digest_campaigns, :preheader_line_1)
    remove_column :digest_campaigns, :preheader_line_2 if column_exists?(:digest_campaigns, :preheader_line_2)

    remove_column :digest_campaigns, :subject_line_1 if column_exists?(:digest_campaigns, :subject_line_1)
    remove_column :digest_campaigns, :subject_line_2 if column_exists?(:digest_campaigns, :subject_line_2)
    remove_column :digest_campaigns, :subject_line_3 if column_exists?(:digest_campaigns, :subject_line_3)
  end
end

# frozen_string_literal: true

class AddCustomHtmlToDigestCampaigns < ActiveRecord::Migration[7.0]
  def up
    return unless table_exists?(:digest_campaigns)

    unless column_exists?(:digest_campaigns, :custom_html_body)
      add_column :digest_campaigns, :custom_html_body, :text
    end

    unless column_exists?(:digest_campaigns, :preheader_line_1)
      add_column :digest_campaigns, :preheader_line_1, :text
    end

    unless column_exists?(:digest_campaigns, :preheader_line_2)
      add_column :digest_campaigns, :preheader_line_2, :text
    end

    # Subject line variants (optional). If provided, a random one is chosen per recipient.
    unless column_exists?(:digest_campaigns, :subject_line_1)
      add_column :digest_campaigns, :subject_line_1, :text
    end
    unless column_exists?(:digest_campaigns, :subject_line_2)
      add_column :digest_campaigns, :subject_line_2, :text
    end
    unless column_exists?(:digest_campaigns, :subject_line_3)
      add_column :digest_campaigns, :subject_line_3, :text
    end
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

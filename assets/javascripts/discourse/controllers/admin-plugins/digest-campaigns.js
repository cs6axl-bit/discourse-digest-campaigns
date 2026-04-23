import Controller from "@ember/controller";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";
import { ajax } from "discourse/lib/ajax";

export default class AdminPluginsDigestCampaignsController extends Controller {
  @tracked campaigns = [];
  @tracked meta = { page: 1, per_page: 30, total: 0, total_pages: 1 };

  @tracked campaign_key = "";
  @tracked selection_sql = "";
  @tracked topic_set_1 = "";
  @tracked topic_set_2 = "";
  @tracked topic_set_3 = "";
  @tracked send_at = ""; // datetime-local
  @tracked test_email = "";

  // Custom HTML campaigns
  @tracked preheader_line_1 = "";
  @tracked preheader_line_2 = "";
  @tracked custom_html_body = "";
  @tracked hardsale_email_html_id = "";
  @tracked bundle_email_id = "";
  @tracked vsl2html_email_id = "";

  // Subject variants (optional; random per recipient)
  @tracked subject_line_1 = "";
  @tracked subject_line_2 = "";
  @tracked subject_line_3 = "";

  // Exclude users who have queue rows in the last X days (on by default)
  @tracked exclude_recent_from_queue = true;
  @tracked exclude_recent_from_queue_days = 1;

  // Exclude users emailed within the last X days (on by default)
  @tracked exclude_recent_emailed = true;
  @tracked exclude_recent_emailed_days = 1;

  // Per-campaign delete behavior (checkbox next to Delete)
  // Default ON when a campaign first appears in the list.
  @tracked deleteQueuedOnDeleteById = {};

  // Existing campaigns table filters
  @tracked hideHardsale = true;
  @tracked campaignSearch = "";
  @tracked createdAfter = "";
  @tracked createdBefore = "";

  @tracked busy = false;
  @tracked error = "";
  @tracked notice = "";

  @tracked draftCount = null;
  @tracked showSqlById = {};
  @tracked testEmailById = {};

  clearMessages() {
    this.error = "";
    this.notice = "";
  }

  @action
  onCustomHtmlChange(val) {
    this.custom_html_body = val || "";
  }
  @action
  onHardsaleEmailHtmlIdInput(event) {
    this.hardsale_email_html_id = event?.target?.value || "";
  }

  @action
  async loadFromHardsaleEmailHtml() {
    this.clearMessages();

    const rawId = (this.hardsale_email_html_id || "").trim();
    if (!rawId) {
      this.error = "Enter an aiwrites_hardsale_email_htmls id first.";
      return;
    }

    const id = Number.parseInt(rawId, 10);
    if (!Number.isInteger(id) || id <= 0) {
      this.error = "Hardsale HTML id must be a positive integer.";
      return;
    }

    this.busy = true;
    try {
      const res = await ajax(`/admin/digest-campaigns/hardsale-email-html/${id}.json`);
      const src = res?.source || {};

      this.subject_line_1 = src.subject_line_1 || "";
      this.subject_line_2 = src.subject_line_2 || "";
      this.subject_line_3 = src.subject_line_3 || "";
      this.preheader_line_1 = src.preheader_line_1 || "";
      this.preheader_line_2 = src.preheader_line_2 || "";
      this.custom_html_body = src.custom_html_body || "";

      this.notice = `Loaded subjects, preheaders, and HTML from aiwrites_hardsale_email_htmls id=${id}.`;
    } catch (e) {
      this.error =
        e?.jqXHR?.responseJSON?.errors?.[0] ||
        e?.message ||
        "Failed to load from aiwrites_hardsale_email_htmls";
    } finally {
      this.busy = false;
    }
  }

  @action
  onBundleEmailIdInput(event) {
    this.bundle_email_id = event?.target?.value || "";
  }

  @action
  onVsl2htmlEmailIdInput(event) {
    this.vsl2html_email_id = event?.target?.value || "";
  }

  @action
  async loadFromVsl2htmlEmail() {
    this.clearMessages();

    const rawId = (this.vsl2html_email_id || "").trim();
    if (!rawId) {
      this.error = "Enter a vsl2html_email_outputs id first.";
      return;
    }

    const id = Number.parseInt(rawId, 10);
    if (!Number.isInteger(id) || id <= 0) {
      this.error = "VSL2HTML email id must be a positive integer.";
      return;
    }

    this.busy = true;
    try {
      const res = await ajax(`/admin/digest-campaigns/vsl2html-email/${id}.json`);
      const src = res?.source || {};

      this.subject_line_1 = src.subject_line_1 || "";
      this.subject_line_2 = src.subject_line_2 || "";
      this.subject_line_3 = src.subject_line_3 || "";
      this.preheader_line_1 = src.preheader_line_1 || "";
      this.preheader_line_2 = src.preheader_line_2 || "";
      this.custom_html_body = src.custom_html_body || "";

      this.notice = `Loaded subjects, preheaders, and HTML from vsl2html_email_outputs id=${id}.`;
    } catch (e) {
      this.error =
        e?.jqXHR?.responseJSON?.errors?.[0] ||
        e?.message ||
        "Failed to load from vsl2html_email_outputs";
    } finally {
      this.busy = false;
    }
  }

  @action
  async loadFromBundleEmail() {
    this.clearMessages();

    const rawId = (this.bundle_email_id || "").trim();
    if (!rawId) {
      this.error = "Enter an aiwrites_hardsale_bundle_emails id first.";
      return;
    }

    const id = Number.parseInt(rawId, 10);
    if (!Number.isInteger(id) || id <= 0) {
      this.error = "Bundle email id must be a positive integer.";
      return;
    }

    this.busy = true;
    try {
      const res = await ajax(`/admin/digest-campaigns/bundle-email/${id}.json`);
      const src = res?.source || {};

      this.subject_line_1 = src.subject_line_1 || "";
      this.subject_line_2 = src.subject_line_2 || "";
      this.subject_line_3 = src.subject_line_3 || "";
      this.preheader_line_1 = src.preheader_line_1 || "";
      this.preheader_line_2 = src.preheader_line_2 || "";
      this.custom_html_body = src.custom_html_body || "";

      this.notice = `Loaded subjects, preheaders, and HTML from aiwrites_hardsale_bundle_emails id=${id}.`;
    } catch (e) {
      this.error =
        e?.jqXHR?.responseJSON?.errors?.[0] ||
        e?.message ||
        "Failed to load from aiwrites_hardsale_bundle_emails";
    } finally {
      this.busy = false;
    }
  }

  formatTopicSets(topicSets) {
    const sets = Array.isArray(topicSets) ? topicSets : [];
    if (!sets.length) {
      return "";
    }
    return sets
      .map((s) => (Array.isArray(s) ? s : []).map((n) => String(n)).join(","))
      .filter((s) => s && s.length > 0)
      .join(" | ");
  }

  async refresh(page = null) {
    const p = page || this.meta?.page || 1;
    const params = new URLSearchParams({ page: p });
    if (this.hideHardsale) params.set("hide_hardsale", "true");
    if (this.campaignSearch.trim()) params.set("search", this.campaignSearch.trim());
    if (this.createdAfter) params.set("created_after", this.createdAfter);
    if (this.createdBefore) params.set("created_before", this.createdBefore);
    const res = await ajax(`/admin/digest-campaigns.json?${params.toString()}`);
    this.campaigns = res.campaigns || [];
    this.meta = res.meta || { page: p, per_page: 30, total: 0, total_pages: 1 };

    // Ensure per-campaign delete checkbox defaults to ON for unseen ids
    const next = { ...(this.deleteQueuedOnDeleteById || {}) };
    for (const c of this.campaigns) {
      if (next[c.id] === undefined) {
        next[c.id] = true;
      }
    }
    this.deleteQueuedOnDeleteById = next;
  }

  @action
  onCampaignSearchInput(event) {
    this.campaignSearch = event?.target?.value || "";
  }

  @action
  onCreatedAfterInput(event) {
    this.createdAfter = event?.target?.value || "";
  }

  @action
  onCreatedBeforeInput(event) {
    this.createdBefore = event?.target?.value || "";
  }

  @action
  onSearchKeydown(event) {
    if (event.key === "Enter") {
      this.applyFilters();
    }
  }

  @action
  async applyFilters() {
    this.clearMessages();
    this.busy = true;
    try {
      await this.refresh(1);
    } catch (e) {
      this.error = e?.message || "Filter failed";
    } finally {
      this.busy = false;
    }
  }

  @action
  async clearFilters() {
    this.campaignSearch = "";
    this.createdAfter = "";
    this.createdBefore = "";
    this.hideHardsale = true;
    this.clearMessages();
    this.busy = true;
    try {
      await this.refresh(1);
    } catch (e) {
      this.error = e?.message || "Refresh failed";
    } finally {
      this.busy = false;
    }
  }

  @action
  toggleSql(id) {
    const current = !!this.showSqlById?.[id];
    this.showSqlById = { ...this.showSqlById, [id]: !current };
  }

  @action
  onTestEmailInput(id, event) {
    const value = event?.target?.value || "";
    this.testEmailById = { ...this.testEmailById, [id]: value };
  }

  @action
  onDeleteQueuedToggle(id, event) {
    const checked = !!event?.target?.checked;
    this.deleteQueuedOnDeleteById = {
      ...this.deleteQueuedOnDeleteById,
      [id]: checked,
    };
  }

  @action
  async refreshNow() {
    this.clearMessages();
    this.busy = true;
    try {
      await this.refresh();
      this.notice = "Refreshed.";
    } catch (e) {
      this.error = e?.message || "Refresh failed";
    } finally {
      this.busy = false;
    }
  }

  @action
  async goToPage(page) {
    const p = parseInt(page, 10);
    if (!p || p <= 0) return;

    this.clearMessages();
    this.busy = true;
    try {
      await this.refresh(p);
    } catch (e) {
      this.error = e?.message || "Pagination failed";
    } finally {
      this.busy = false;
    }
  }

  @action
  async nextPage() {
    const p = (this.meta?.page || 1) + 1;
    if (p > (this.meta?.total_pages || 1)) return;
    await this.goToPage(p);
  }

  @action
  async prevPage() {
    const p = (this.meta?.page || 1) - 1;
    if (p < 1) return;
    await this.goToPage(p);
  }

  @action
  async countDraftRecords() {
    this.clearMessages();
    this.busy = true;
    this.draftCount = null;

    try {
      const res = await ajax("/admin/digest-campaigns/count.json", {
        type: "POST",
        data: {
          selection_sql: this.selection_sql,
          exclude_recent_from_queue: this.exclude_recent_from_queue,
          exclude_recent_from_queue_days: this.exclude_recent_from_queue_days,
          exclude_recent_emailed: this.exclude_recent_emailed,
          exclude_recent_emailed_days: this.exclude_recent_emailed_days,
        },
      });
      this.draftCount = res?.count;
      this.notice = `Query returned ${res?.count} record(s).`;
    } catch (e) {
      this.error =
        e?.jqXHR?.responseJSON?.errors?.[0] || e?.message || "Count failed";
    } finally {
      this.busy = false;
    }
  }

  @action
  async testDraft() {
    this.clearMessages();
    const email = (this.test_email || "").trim();
    if (!email) {
      this.error = "Enter a test_email first.";
      return;
    }

    this.busy = true;
    try {
      const payload = {
        campaign_key: this.campaign_key,
        selection_sql: this.selection_sql,
        topic_set_1: this.topic_set_1,
        topic_set_2: this.topic_set_2,
        topic_set_3: this.topic_set_3,
        subject_line_1: this.subject_line_1,
        subject_line_2: this.subject_line_2,
        subject_line_3: this.subject_line_3,
        preheader_line_1: this.preheader_line_1,
        preheader_line_2: this.preheader_line_2,
        custom_html_body: this.custom_html_body,
        test_email: email,
      };

      if (this.send_at && this.send_at.trim().length > 0) {
        const d = new Date(this.send_at);
        payload.send_at = d.toISOString();
      }

      const res = await ajax("/admin/digest-campaigns/test-draft.json", {
        type: "POST",
        data: payload,
      });

      const chosen = res?.test?.chosen_topic_ids?.join(",") || "";
      this.notice = `Draft test sent to ${email}${
        chosen ? ` (topics: ${chosen})` : ""
      }.`;
    } catch (e) {
      this.error =
        e?.jqXHR?.responseJSON?.errors?.[0] ||
        e?.message ||
        "Draft test failed";
    } finally {
      this.busy = false;
    }
  }

  @action
  async createCampaign() {
    this.clearMessages();

    if (!confirm("Save this campaign and populate the send queue?")) return;

    this.busy = true;

    try {
      const payload = {
        campaign_key: this.campaign_key,
        selection_sql: this.selection_sql,
        topic_set_1: this.topic_set_1,
        topic_set_2: this.topic_set_2,
        topic_set_3: this.topic_set_3,
        subject_line_1: this.subject_line_1,
        subject_line_2: this.subject_line_2,
        subject_line_3: this.subject_line_3,
        preheader_line_1: this.preheader_line_1,
        preheader_line_2: this.preheader_line_2,
        custom_html_body: this.custom_html_body,
        test_email: this.test_email,
        exclude_recent_from_queue: this.exclude_recent_from_queue,
        exclude_recent_from_queue_days: this.exclude_recent_from_queue_days,
        exclude_recent_emailed: this.exclude_recent_emailed,
        exclude_recent_emailed_days: this.exclude_recent_emailed_days,
      };

      if (this.send_at && this.send_at.trim().length > 0) {
        const d = new Date(this.send_at);
        payload.send_at = d.toISOString();
      }

      await ajax("/admin/digest-campaigns.json", { type: "POST", data: payload });

      this.notice = "Campaign created and queue populated.";
      this.campaign_key = "";
      this.selection_sql = "";
      this.topic_set_1 = "";
      this.topic_set_2 = "";
      this.topic_set_3 = "";
      this.send_at = "";
      this.test_email = "";
      this.subject_line_1 = "";
      this.subject_line_2 = "";
      this.subject_line_3 = "";
      this.preheader_line_1 = "";
      this.preheader_line_2 = "";
      this.custom_html_body = "";
      this.hardsale_email_html_id = "";
      this.bundle_email_id = "";
      this.vsl2html_email_id = "";
      this.exclude_recent_from_queue = true;
      this.exclude_recent_from_queue_days = 1;
      this.exclude_recent_emailed = true;
      this.exclude_recent_emailed_days = 1;

      await this.refresh(1);
    } catch (e) {
      this.error =
        e?.jqXHR?.responseJSON?.errors?.[0] ||
        e?.message ||
        "Failed to create campaign";
    } finally {
      this.busy = false;
    }
  }

  @action
  async enableCampaign(id) {
    this.clearMessages();
    this.busy = true;
    try {
      await ajax(`/admin/digest-campaigns/${id}/enable.json`, { type: "PUT" });
      this.notice = "Enabled.";
      await this.refresh();
    } catch (e) {
      this.error =
        e?.jqXHR?.responseJSON?.errors?.[0] || e?.message || "Enable failed";
    } finally {
      this.busy = false;
    }
  }

  @action
  async disableCampaign(id) {
    this.clearMessages();
    this.busy = true;
    try {
      await ajax(`/admin/digest-campaigns/${id}/disable.json`, { type: "PUT" });
      this.notice = "Disabled.";
      await this.refresh();
    } catch (e) {
      this.error =
        e?.jqXHR?.responseJSON?.errors?.[0] || e?.message || "Disable failed";
    } finally {
      this.busy = false;
    }
  }

  @action
  async deleteCampaign(id) {
    this.clearMessages();

    // default-to-true if unset, so deleteQueued matches the checkbox behavior
    const stored = this.deleteQueuedOnDeleteById?.[id];
    const deleteQueued = stored === false ? false : true;

    const msg = deleteQueued
      ? "Delete this campaign? Queued rows will be removed; other statuses (sent/processing/failed/skipped) remain."
      : "Delete this campaign? No queue rows will be removed.";

    if (!confirm(msg)) return;

    this.busy = true;
    try {
      await ajax(`/admin/digest-campaigns/${id}.json`, {
        type: "DELETE",
        data: { delete_queued_rows: deleteQueued },
      });
      this.notice = "Deleted.";
      await this.refresh();
    } catch (e) {
      this.error =
        e?.jqXHR?.responseJSON?.errors?.[0] || e?.message || "Delete failed";
    } finally {
      this.busy = false;
    }
  }

  @action
  async testSend(id) {
    this.clearMessages();
    const email = (this.testEmailById?.[id] || "").trim();
    if (!email) {
      this.error = "Enter a test email for this campaign.";
      return;
    }

    this.busy = true;
    try {
      await ajax(`/admin/digest-campaigns/${id}/test.json`, {
        type: "POST",
        data: { test_email: email },
      });
      this.notice = `Test sent to ${email}`;
    } catch (e) {
      this.error =
        e?.jqXHR?.responseJSON?.errors?.[0] ||
        e?.message ||
        "Test send failed";
    } finally {
      this.busy = false;
    }
  }
}

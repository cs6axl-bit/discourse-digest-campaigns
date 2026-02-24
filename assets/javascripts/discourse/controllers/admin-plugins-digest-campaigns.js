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


  formatTopicSets(topicSets) {
    const sets = Array.isArray(topicSets) ? topicSets : [];
    if (!sets.length) {
      return "";
    }
    // Print as a readable string (NOT JSON)
    // Example: "3782,1351,1423 | 99,101 | 555"
    return sets
      .map((s) => (Array.isArray(s) ? s : []).map((n) => String(n)).join(","))
      .filter((s) => s && s.length > 0)
      .join(" | ");
  }


  async refresh(page = null) {
    const p = page || this.meta?.page || 1;
    const res = await ajax(`/admin/digest-campaigns.json?page=${p}`);
    this.campaigns = res.campaigns || [];
    this.meta = res.meta || { page: p, per_page: 30, total: 0, total_pages: 1 };
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
    if (!p || p <= 0) {
      return;
    }

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
    if (p > (this.meta?.total_pages || 1)) {
      return;
    }
    await this.goToPage(p);
  }

  @action
  async prevPage() {
    const p = (this.meta?.page || 1) - 1;
    if (p < 1) {
      return;
    }
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
        data: { selection_sql: this.selection_sql },
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
      this.notice = `Draft test sent to ${email}${chosen ? ` (topics: ${chosen})` : ""}.`;
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
    this.busy = true;

    try {
      const payload = {
        campaign_key: this.campaign_key,
        selection_sql: this.selection_sql,
        topic_set_1: this.topic_set_1,
        topic_set_2: this.topic_set_2,
        topic_set_3: this.topic_set_3,
        test_email: this.test_email,
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
    if (
      !confirm(
        "Delete this campaign? (Queue rows remain unless you remove them manually.)"
      )
    ) {
      return;
    }

    this.busy = true;
    try {
      await ajax(`/admin/digest-campaigns/${id}.json`, { type: "DELETE" });
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

import Route from "@ember/routing/route";
import { ajax } from "discourse/lib/ajax";

export default class AdminPluginsDigestCampaignsRoute extends Route {
  async model() {
    return await ajax("/admin/digest-campaigns.json?page=1");
  }

  setupController(controller, model) {
    super.setupController(controller, model);
    controller.campaigns = model?.campaigns || [];
    controller.meta = model?.meta || { page: 1, per_page: 30, total: 0, total_pages: 1 };
  }
}

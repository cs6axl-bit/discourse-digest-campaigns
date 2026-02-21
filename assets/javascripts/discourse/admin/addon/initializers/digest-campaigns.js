import { withPluginApi } from "discourse/lib/plugin-api";

export default {
  name: "digest-campaigns-admin",
  initialize() {
    withPluginApi("0.8.7", (api) => {
      // Adds /admin/digest-campaigns and shows it in the admin nav
      api.addAdminRoute("digest-campaigns", "digest-campaigns");
    });
  },
};

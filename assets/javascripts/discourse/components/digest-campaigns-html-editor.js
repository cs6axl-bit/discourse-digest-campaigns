import Component from "@glimmer/component";
import { action } from "@ember/object";

// TinyMCE is NOT bundled with Discourse core.
// If you load TinyMCE globally (window.tinymce) via your own theme/component,
// this component will auto-initialize it. Otherwise it gracefully falls back
// to a plain textarea.
export default class DigestCampaignsHtmlEditor extends Component {
  @action
  onInput(event) {
    if (typeof this.args?.onChange === "function") {
      this.args.onChange(event?.target?.value || "");
    }
  }

  @action
  setup(element) {
    try {
      const textarea = element?.querySelector("textarea");
      if (!textarea) return;

      const tinymce = window?.tinymce;
      if (!tinymce || typeof tinymce.init !== "function") return;

      // Avoid double-init
      if (textarea.dataset?.tinymceInited === "1") return;
      textarea.dataset.tinymceInited = "1";

      // Give it a stable id for TinyMCE selector
      if (!textarea.id) {
        textarea.id = `dc_html_${Math.random().toString(16).slice(2)}`;
      }

      tinymce.init({
        selector: `#${textarea.id}`,
        menubar: false,
        branding: false,
        plugins: "link lists code",
        toolbar:
          "undo redo | bold italic underline | bullist numlist | link | removeformat | code",
        height: 320,
        setup: (ed) => {
          ed.on("change keyup setcontent", () => {
            const html = ed.getContent() || "";
            if (typeof this.args?.onChange === "function") {
              this.args.onChange(html);
            }
          });
        },
      });
    } catch (e) {
      // Fallback: leave textarea as-is
      // eslint-disable-next-line no-console
      console.warn("digest-campaigns TinyMCE init failed", e);
    }
  }
}

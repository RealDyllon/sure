import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="page-polling"
// Periodically revisits the current page while a background task is running.
export default class extends Controller {
  static values = {
    url: String,
    interval: { type: Number, default: 3000 },
  };

  connect() {
    if (!this.hasUrlValue) return;

    this.timeout = setTimeout(() => {
      Turbo.visit(this.urlValue, { action: "replace" });
    }, this.intervalValue);
  }

  disconnect() {
    if (this.timeout) {
      clearTimeout(this.timeout);
      this.timeout = null;
    }
  }
}

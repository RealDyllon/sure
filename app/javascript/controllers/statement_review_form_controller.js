import { Controller } from "@hotwired/stimulus";

const PRIMARY_CLASSES = [
  "text-inverse",
  "bg-inverse",
  "hover:bg-inverse-hover",
];
const SECONDARY_CLASSES = [
  "text-primary",
  "bg-surface-inset",
  "hover:bg-surface-inset-hover",
];

// Connects to data-controller="statement-review-form"
export default class extends Controller {
  static targets = ["saveButton", "publishButton"];
  static values = {
    clean: Boolean,
  };

  connect() {
    this.updateButtons();
  }

  markDirty() {
    this.cleanValue = false;
    this.updateButtons();
  }

  updateButtons() {
    this.setPrimary(this.saveButtonTarget, !this.cleanValue);

    if (this.hasPublishButtonTarget) {
      this.setPrimary(this.publishButtonTarget, this.cleanValue);
    }
  }

  setPrimary(button, primary) {
    button.classList.remove(...PRIMARY_CLASSES, ...SECONDARY_CLASSES);
    button.classList.add(...(primary ? PRIMARY_CLASSES : SECONDARY_CLASSES));
  }
}

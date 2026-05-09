import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="statement-review"
export default class extends Controller {
  static targets = ["action", "existingAccountField", "existingAccountSelect"];

  connect() {
    this.update();
  }

  update() {
    const creatingAccount = this.actionTarget.value === "create";

    this.existingAccountFieldTarget.classList.toggle(
      "invisible",
      creatingAccount,
    );
    this.existingAccountFieldTarget.setAttribute(
      "aria-hidden",
      creatingAccount ? "true" : "false",
    );
    this.existingAccountSelectTarget.disabled = creatingAccount;
  }
}

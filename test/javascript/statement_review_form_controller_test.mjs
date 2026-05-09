import { describe, it } from "node:test"
import assert from "node:assert/strict"
import fs from "node:fs"
import vm from "node:vm"

function loadController() {
  const source = fs.readFileSync(
    new URL("../../app/javascript/controllers/statement_review_form_controller.js", import.meta.url),
    "utf8",
  )
  const script = source
    .replace('import { Controller } from "@hotwired/stimulus";', "")
    .replace("export default class extends Controller", "class StatementReviewFormController extends Controller")
    .concat("\nStatementReviewFormController;")

  class Controller {}
  return vm.runInNewContext(script, { Controller })
}

function button() {
  const classes = new Set()

  return {
    disabled: false,
    attributes: {},
    classList: {
      add: (...tokens) => tokens.forEach((token) => classes.add(token)),
      remove: (...tokens) => tokens.forEach((token) => classes.delete(token)),
      contains: (token) => classes.has(token),
    },
    setAttribute(name, value) {
      this.attributes[name] = value
    },
    removeAttribute(name) {
      delete this.attributes[name]
    },
  }
}

describe("statement review form controller", () => {
  it("disables publishing after review fields become dirty", () => {
    const ControllerClass = loadController()
    const controller = new ControllerClass()
    controller.saveButtonTarget = button()
    controller.publishButtonTarget = button()
    controller.hasPublishButtonTarget = true
    controller.cleanValue = true

    controller.connect()
    assert.equal(controller.publishButtonTarget.disabled, false)
    assert.equal(controller.publishButtonTarget.attributes["aria-disabled"], undefined)

    controller.markDirty()

    assert.equal(controller.cleanValue, false)
    assert.equal(controller.publishButtonTarget.disabled, true)
    assert.equal(controller.publishButtonTarget.attributes["aria-disabled"], "true")
    assert.equal(controller.saveButtonTarget.classList.contains("bg-inverse"), true)
    assert.equal(controller.publishButtonTarget.classList.contains("bg-surface-inset"), true)
  })
})

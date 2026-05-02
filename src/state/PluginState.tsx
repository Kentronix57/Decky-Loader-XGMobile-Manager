// * All of your state property types go here.
export interface PublicPluginState {
  buttonLabel: string
}

// * All of your state setter types go here.
export interface PublicPluginContext extends PublicPluginState {
  setButtonLabel(label: string): void;
}

// * Define your property defaults and setter logic here.
export class PluginState {
  private buttonLabel: string = "Click Me";

  public eventBus = new EventTarget();

  getPublicState() {
    return {
      "buttonLabel": this.buttonLabel
    }
  }

  setButtonLabel(label: string): void {
    this.buttonLabel = label;
    this.forceUpdate();
  }

  private forceUpdate(): void {
    this.eventBus.dispatchEvent(new Event("stateUpdate"));
  }
}

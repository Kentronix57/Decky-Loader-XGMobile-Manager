import { PythonInterop } from "./PythonInterop";
import { SteamController } from "./SteamController";
import { LogController } from "./LogController";
import { PluginState } from "../../state/PluginState";

/**
 * Main controller class for the plugin.
 */
export class PluginController {
  // * This gives you access to the plugin state from your main controller class.
  private static pluginState: PluginState;

  private static steamController: SteamController;

  /**
   * Sets the plugin's serverAPI.
   * @param pluginState The plugin's state management.
   */
  static setup(pluginState: PluginState): void {
    LogController.setup("xgmobile-manager", "ff3e00");

    this.pluginState = pluginState;
    this.steamController = new SteamController();
  }

  /**
   * Sets the plugin to initialize once the user logs in.
   * @returns The unregister function for the login hook.
   */
  static initOnLogin(onMount: () => Promise<void>): Unregisterer {
    return this.steamController.registerForAuthStateChange(
      // * This function will get passed the current user's username as its first argument.
      async () => {
        if (await this.steamController.waitForServicesToInitialize()) {
          await PluginController.init();
          onMount();
        } else {
          PythonInterop.toast("Error", "Failed to initialize, try restarting.");
        }
      },
      // * This function will get passed the current user's username as its first argument.
      async () => { },
      true,
      true
    );
  }

  /**
   * Initializes the Plugin.
   */
  static async init(): Promise<void> {
    LogController.log("PluginController initialized.");
    
    // TODO: perform any logic you want to run when the plugin first initializes here.
  }

  /**
   * Function to run when the plugin dismounts.
   */
  static dismount(): void {
    // TODO: dispose of any listeners and perform other cleanup here.
    LogController.log("PluginController dismounted.");
  }
}

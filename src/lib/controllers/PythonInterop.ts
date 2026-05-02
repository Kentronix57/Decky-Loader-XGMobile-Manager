import { call, toaster } from "@decky/api";

/**
 * Class for frontend -> backend communication.
 */
export class PythonInterop {
  /**
   * Logs a message to the plugin's log file and the frontend console.
   * @param message The message to log.
   */
  static async log(message: string): Promise<void> {
    await call<[message: string, level: number], boolean>("logMessage", `[front-end]: ${message}`, 0);
  }

  /**
   * Logs a warning to the plugin's log file and the frontend console.
   * @param message The message to log.
   */
  static async warn(message: string): Promise<void> {
    await call<[message: string, level: number], boolean>("logMessage", `[front-end]: ${message}`, 1);
  }

  /**
   * Logs an error to the plugin's log file and the frontend console.
   * @param message The message to log.
   */
  static async error(message: string): Promise<void> {
    await call<[message: string, level: number], boolean>("logMessage", `[front-end]: ${message}`, 2);
  }


  /**
   * Sets the plugin's demo settings.
   * @param demo The plugin's demo settings.
   * @returns A promise resolving to whether or not the demo settings were successfully set.
   */
  static async setDemo(demo: string): Promise<void | Error> {
    try {
      return await call<[ demo: string ], void>("set_demo", demo);
    } catch (e: any) {
      return e;
    }
  }

  /**
   * Shows a toast message.
   * @param title The title of the toast.
   * @param message The message of the toast.
   */
  /*static toast(title: string, message: string): void {
    return (() => {
      try {
        return toaster.toast({
          title: title,
          body: message,
          duration: 8000,
        });
      } catch (e) {
        console.log("Toaster Error", e);
      }
    }*/
   static toast(title: string, message: string): any { 
    // using 'any' or 'ToastNotification | undefined'
    try {
      return toaster.toast({
        title: title,
        body: message,
        duration: 8000,
      });
    } catch (e) {
      console.log("Toaster Error", e);
    }//)();
  }
}

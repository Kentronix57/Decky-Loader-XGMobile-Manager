import { debounce } from '../Utils';
import { PythonInterop } from "./PythonInterop";

const errorToastLimit = 10;

/**
 * The logging controller for the Plugin.
 */
export class LogController {
  private static pluginName: string;
  private static pluginColor: string;
  private static infoColor: string;
  private static warningColor: string;
  private static errorColor: string;

  /**
   * Error flag to check for showing a problem has occured in the QAM.
   */
  static errorFlag = false;

  /**
   * Counts of raised error massages
   */
  static errorCounts: {[message: string]: number} = {};

  /**
   * Sets up the plugin logger.
   * @param pluginName The name of the plugin (in UpperCamelCase).
   * @param pluginColor The main color of the plugin.
   * @param infoColor The color for info messages. Defaults to **1abc9c**
   * @param warningColor The color for warning messages. Defaults to **e3c907**
   * @param errorColor The color for error messages. Defaults to **c70808**
   */
  static setup(pluginName: string, pluginColor: string, infoColor = "1abc9c", warningColor = "e3c907", errorColor = "c70808"): void {
    LogController.pluginName = pluginName;
    LogController.pluginColor = pluginColor;
    LogController.infoColor = infoColor;
    LogController.warningColor = warningColor;
    LogController.errorColor = errorColor;
  }

  /**
   * Logs a message to the plugin's log file and the frontend console.
   * @param message The message to log.
   */
	static log(...args: any[]) {
    console.log(
      `%c ${LogController.pluginName} %c INFO %c`,
      `background: #${LogController.pluginColor}; color: black;`,
      `background: #${LogController.infoColor}; color: black;`,
      'background: transparent;',
      ...args
    );
    PythonInterop.log(args.join(" "));
  }

  /**
   * Logs a warning to the plugin's log file and the frontend console.
   */
	static warn(...args: any[]) {
    console.warn(
      `%c ${LogController.pluginName} %c WARNING %c`,
      `background: #${LogController.pluginColor}; color: black;`,
      `background: #${LogController.warningColor}; color: black;`,
      'background: transparent;',
      ...args
    );
    PythonInterop.warn(args.join(" "));
  }

  /**
   * Logs an error to the plugin's log file and the frontend console.
   */
	static error(...args: any[]) {
    console.error(
      `%c ${LogController.pluginName} %c ERROR %c`,
      `background: #${LogController.pluginColor}; color: black;`,
      `background: #${LogController.errorColor}; color: black;`,
      'background: transparent;',
      ...args
    );
    PythonInterop.error(args.join(" "));
  }

  /**
   * Throws a new error and logs it to the plugin's log file.
   */
	static throw(...args: any[]) {
    PythonInterop.error(args.join(" "));

    throw new Error([
      `%c ${LogController.pluginName} %c ERROR %c`,
      `background: #${LogController.pluginColor}; color: black;`,
      `background: #${LogController.errorColor}; color: black;`,
      'background: transparent;',
      ...args
    ].join(' '));
  }

  /**
   * Logs error to backend, frontend, and toasts the error and sets the error flag to show in QAM.
   *
   * intended for patching/ ui errors but may be useful for other cases in the future.
   */
  static raiseError = debounce((...args: any[]) => {
    const msg = args.join(" ");
    PythonInterop.error(msg);
    LogController.error(...args);

    if (!LogController.errorCounts[msg]) LogController.errorCounts[msg] = 0;
    if (LogController.errorCounts[msg] <= errorToastLimit) PythonInterop.toast(`${LogController.pluginName} ERROR`, msg);

    LogController.errorCounts[msg]++;
    LogController.errorFlag = true;
  }, 5000, true) as (...args: any[]) => void;
}

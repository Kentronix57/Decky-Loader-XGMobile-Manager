import { sleep } from '@decky/ui';

/**
 * Waits for a condition to be true.
 * @param retries The number of times to retry the condition.
 * @param delay The time (in ms) between retdecky-frontend-libries.
 * @param check The condition to check.
 * @returns A promise resolving to true if the check was true on any attempt, or false if it failed each time.
 */
export async function waitForCondition(retries: number, delay: number, check: () => (boolean | Promise<boolean>)): Promise<boolean> {
  const waitImpl = async (): Promise<boolean> => {
    try {
      let tries = retries + 1;
      while (tries-- !== 0) {
        if (await check()) {
          return true;
        }

        if (tries > 0) {
          await sleep(delay);
        }
      }
    } catch (error) {
      console.error(error);
    }

    return false;
  };

  return await waitImpl();
}

/**
 * Gets a steam user id from two parts.
 * @param low The low part of the bigint.
 * @param high The high part of the bigint.
 * @returns The user's id as a bigint.
 */
export function getSteamIdFromParts(low: number, high: number): bigint {
  return (BigInt(high) << 32n) | (BigInt(low));
}

/**
 * Gets a steam user id from two parts.
 * @param low The low part of the bigint.
 * @param high The high part of the bigint.
 * @returns The user's id as a number.
 */
export function getNonBigIntUserId(low: number, high: number): number {
  return Number(getSteamIdFromParts(low, high) - 76561197960265728n);
}

/**
 * Gets the current user's steam id.
 * @param useU64 Whether or not the id should be a u64.
 * @returns The user's steam id.
 */
export function getCurrentUserId(useU64 = false): string {
  if (useU64) return window.App.m_CurrentUser.strSteamID;
  return BigInt.asUintN(32, BigInt(window.App.m_CurrentUser.strSteamID)).toString();
};

export function debounce(func:Function, wait:number, immediate?:boolean) {
  let timeout:NodeJS.Timeout|null;
  return function (this:any) {
      const context = this, args = arguments;
      const later = function () {
          timeout = null;
          if (!immediate) func.apply(context, args);
      };
      const callNow = immediate && !timeout;
      clearTimeout(timeout as NodeJS.Timeout);
      timeout = setTimeout(later, wait);
      if (callNow) func.apply(context, args);
  };
}

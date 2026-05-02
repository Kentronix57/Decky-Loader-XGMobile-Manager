import { gamepadDialogClasses, quickAccessControlsClasses } from "@decky/ui";
import { FC } from "react";

/**
 * All css styling for the Quick Access Menu part of the Plugin.
 */
export const QamStyles: FC<{}> = ({}) => {
  return (
    <style>{`
      .xgmobile-manager-scope {
        width: inherit;
        height: inherit;

        flex: 1 1 1px;
        scroll-padding: 48px 0px;
        display: flex;
        flex-direction: column;
        justify-content: flex-start;
        align-content: stretch;
      }

      .xgmobile-manager-scope .${quickAccessControlsClasses.PanelSection} {
        padding: 0px;
        margin: 0px;
        width: 100%;
      }

      .xgmobile-manager-scope .${quickAccessControlsClasses.PanelSectionTitle} {
        margin-top: 3px;
        margin-left: 16px;
      }

      .xgmobile-manager-scope .${gamepadDialogClasses.FieldDescription} {
        margin: 0px 16px;
        margin-top: 5px;
      }
      .xgmobile-manager-scope .${gamepadDialogClasses.FieldLabel} {
        margin-left: 16px;
      }

      .xgmobile-manager-scope .seperator {
        width: 100%;
        height: 1px;
        background: #23262e;
      }
    `}</style>
  );
}

import { DialogButton, Navigation } from "@decky/ui";
import { FC } from "react";

/**
 * An example of having a custom route for a Plugin.
 */
export const PluginRouterDemo: FC = () => {
  return (
    <div style={{ marginTop: "50px", color: "white" }}>
      Hello World!
      <DialogButton onClick={() => Navigation.NavigateToLibraryTab()}>
        Go to Library
      </DialogButton>
    </div>
  );
};

import { SiAsus } from "react-icons/si";
import { BsGpuCard } from "react-icons/bs"; 
import { definePlugin } from "@decky/api"; 
import { staticClasses } from "@decky/ui";
import React from "react";

import { PluginController } from "./lib/controllers/PluginController";
import { PluginContextProvider } from "./state/PluginContext";
import { PluginState } from "./state/PluginState";
import { QuickAccessContent } from "./components/QuickAccessContent";

export default definePlugin(() => {
  const pluginState = new PluginState();
  PluginController.setup(pluginState);

  const loginUnregisterer = PluginController.initOnLogin(async () => {
    // Initialization logic
  });

  return {
    name: "ASUS XGMobile Manager",
    title: <div className={staticClasses.Title}>ASUS XGMobile Manager</div>,
    content: (
      <PluginContextProvider PluginStateClass={pluginState}>
        <QuickAccessContent />
      </PluginContextProvider>
    ),
    icon: <BsGpuCard />, //<SiAsus />
    onDismount: () => {
      loginUnregisterer.unregister();
      PluginController.dismount();
    },
  };
});

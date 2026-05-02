import { createContext, useContext, useEffect, useState, ReactNode } from "react";
import { PluginState, PublicPluginContext, PublicPluginState } from "./PluginState";

const PluginContext = createContext<PublicPluginContext>(null as any);

export const usePluginState = () => useContext(PluginContext);

interface ProviderProps {
  children: ReactNode;
  PluginStateClass: PluginState;
}

export const PluginContextProvider = ({
  children,
  PluginStateClass
}: ProviderProps) => {
  const [publicState, setPublicState] = useState<PublicPluginState>({ 
    ...PluginStateClass.getPublicState() 
  });

  useEffect(() => {
    const onUpdate = () => {
      setPublicState({ ...PluginStateClass.getPublicState() });
    };

    PluginStateClass.eventBus.addEventListener("stateUpdate", onUpdate);

    return () => {
      PluginStateClass.eventBus.removeEventListener("stateUpdate", onUpdate);
    };
  }, [PluginStateClass]);

  // Setter wrappers
  const setButtonLabel = (label: string) => {
    PluginStateClass.setButtonLabel(label);
  };

  return (
    <PluginContext.Provider
      value={{
        ...publicState,
        setButtonLabel
      }}
    >
      {children}
    </PluginContext.Provider>
  );
};

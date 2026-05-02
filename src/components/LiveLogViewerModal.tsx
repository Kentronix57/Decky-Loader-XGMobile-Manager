import React, { useEffect, useState, useRef, FC } from "react";
import { 
  ModalRoot, 
  DialogHeader, 
  DialogBody, 
  Focusable 
} from "@decky/ui";
import { call } from "@decky/api";

interface LiveLogViewerModalProps {
  closeModal?: () => void;
  logType: string;
}

export const LiveLogViewerModal: FC<LiveLogViewerModalProps> = ({ closeModal, logType }) => {
  const [logText, setLogText] = useState("Initializing...");
  const scrollRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const interval = setInterval(async () => {
      try {
        const logs = await call("get_live_logs", logType) as string;
        if (logs) setLogText(logs);
      } catch (e) {
        console.error("Polling error:", e);
      }
    }, 500);

    return () => clearInterval(interval);
  }, [logType]);

  useEffect(() => {
    if (scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
    }
  }, [logText]);

  return (
    <ModalRoot onCancel={closeModal}>
      <DialogHeader>XG Mobile Maintenance</DialogHeader>
      <DialogBody>
        <Focusable>
          <div 
            ref={scrollRef}
            style={{ 
              backgroundColor: "#000000", 
              color: "#1df51d", 
              padding: "12px", 
              fontFamily: "monospace", 
              height: "350px", 
              overflowY: "auto",
              fontSize: "12px", 
              borderRadius: "4px",
              whiteSpace: "pre-wrap"
            }}
          >
            {logText}
          </div>
        </Focusable>
      </DialogBody>
    </ModalRoot>
  );
};

import { Dropdown, DialogBody, DialogHeader, ScrollPanel, DropdownOption, ModalRoot } from '@decky/ui';
import { useEffect, useState, FC } from 'react';
import { call } from "@decky/api";

const LOG_OPTIONS: DropdownOption[] = [
  { data: 'enable', label: 'Enable Log' },
  { data: 'eject', label: 'Eject Log' },
  { data: 'install', label: 'NVIDIA Install Log' },
  { data: 'repair', label: 'Repair Services Log' },
  { data: 'nuke', label: 'Reset Environment Log' },
  { data: 'debug', label: 'Debug Logs' }
];

interface LogViewerModalProps {
  closeModal?: () => void;
}

export const LogViewerModal: FC<LogViewerModalProps> = ({ closeModal }) => {
  const [logType, setSelectedLog] = useState<string | number>('install');
  const [logText, setLogText] = useState("Reading log...");

  useEffect(() => {
    const fetchLog = async () => {
      try {
        const logs = await call("get_latest_logs", logType ) as string;
        setLogText(logs || `No logs found for ${logType}.`);
      } catch (e) {
        setLogText("Backend connection failed.");
      }
    };
    fetchLog();
  }, [logType]);
  
  return (
    <ModalRoot onCancel={closeModal}>
      <DialogHeader>Activity Logs</DialogHeader>
      <DialogBody>
        <div style={{ display: 'flex', flexDirection: 'column', gap: '15px' }}>
          
          <Dropdown
            rgOptions={LOG_OPTIONS}
            selectedOption={logType}
            onChange={(option) => setSelectedLog(option.data)}
          />

          <div style={{ height: '400px', backgroundColor: '#000000', borderRadius: '4px' }}>
            <ScrollPanel>
              {}
              <div style={{ 
                padding: '10px'  /*, Dunno if I want this green or not 
                fontFamily: 'monospace', 
                whiteSpace: 'pre-wrap', 
                fontSize: '12px',
                color: '#1df51d'*/
              }}>
                {logText}
              </div>
            </ScrollPanel>
          </div>

        </div>
      </DialogBody>
    </ModalRoot>
  );
};

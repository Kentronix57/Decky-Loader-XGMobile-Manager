import { Dropdown, DialogBody, DialogHeader, ScrollPanel, DropdownOption, ModalRoot } from '@decky/ui';
import { useEffect, useState, FC } from 'react';
import { call } from "@decky/api";

const LOG_OPTIONS: DropdownOption[] = [
  { data: 'enable', label: 'Enable Log' },
  { data: 'enabledesktop', label: 'Enable Desktop Link Log' },
  { data: 'eject', label: 'Eject Log' },
  { data: 'ejectdesktop', label: 'Eject Desktop Link Log' },
  { data: 'transition', label: 'Desktop Transition Log' },
  { data: 'hybrid', label: 'Supergfx Hybrid Log' },
  { data: 'integrated', label: 'Supergfx Integrated Log' },
  { data: 'install', label: 'NVIDIA Install Log' },
  //{ data: 'repair', label: 'Repair Services Log' },
  { data: 'uninstall', label: 'Reset Environment Log' },
  { data: 'shortcuts', label: 'Install Desktop Shortcuts Log' },
  { data: 'sync', label: 'Boot NVIDIA DRM sync Log' },
  { data: 'python', label: 'Python Critical Error Log' },
  { data: 'debug', label: 'Debug Log' }
];

interface LogViewerModalProps {
  closeModal?: () => void;
}

export const LogViewerModal: FC<LogViewerModalProps> = ({ closeModal }) => {
  const [logType, setSelectedLog] = useState<string | number>('enable');
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

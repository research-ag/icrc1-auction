import { existsSync, unlinkSync, writeFileSync } from 'fs';
import path from 'path';
import { PocketIc, PocketIcServer } from '@hadronous/pic';
import { tmpdir } from 'os';

module.exports = async () => {
  const pid = process.ppid;
  const serverUrlFile = path.resolve(tmpdir(), 'pic_server_url.txt');
  const picServerPidFile = path.resolve(tmpdir(), 'pic_server.pid');
  const portFilePath = path.resolve(tmpdir(), `pocket_ic_${pid}.port`);

  if (existsSync(serverUrlFile)) {
    unlinkSync(serverUrlFile);
  }
  if (existsSync(picServerPidFile)) {
    unlinkSync(picServerPidFile);
  }
  if (existsSync(portFilePath)) {
    unlinkSync(portFilePath);
  }

  console.log('Starting PIC server...');
  let picServer = await PocketIcServer.start({ showCanisterLogs: false, showRuntimeLogs: false });
  console.log('Started PIC server. Waiting for state availability with certification...');
  let pic: PocketIc | null = null;
  let timeout = 300;
  try {
    pic = await Promise.race([
      PocketIc.create(picServer.getUrl()),
      new Promise((_, rej) => setTimeout(rej, timeout*1000)) as Promise<PocketIc>
    ]);
  } catch (e) {
    throw new Error('Pocket IC instance was unable to start in ' + timeout + ' seconds. Aborting....');
  }
  if (pic) {
    console.log('PocketIc created. Killing it now');
    await pic.tearDown();
    writeFileSync(serverUrlFile, picServer.getUrl(), 'utf-8');
    writeFileSync(picServerPidFile, (picServer as any).serverProcess.pid.toString(), 'utf-8');
    console.log(`Pic server runs at url ${picServer.getUrl()}. File saved at path ${serverUrlFile}`);
  }
};

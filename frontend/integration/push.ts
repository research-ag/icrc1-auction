import { useEffect, useRef, useState } from 'react';
import { useMutation, useQuery, useQueryClient } from 'react-query';
import { useSnackbar } from 'notistack';
import { useAuction, useAuctionCanisterId } from './index';
import { useIdentity } from './identity';
import { HttpAgent } from '@icp-sdk/core/agent';

type AnyWebPushClient = any;
const SERVICE_WORKER_PATH = '/ic-web-push-sw.js';

export type PushStatus = {
  permission: NotificationPermission;
  subscribed: boolean;
  enabledByUserSettings: boolean; // from canister flag
  effectiveEnabled: boolean; // subscribed && permission === 'granted' && enabledByUserSettings
  lastError?: string;
};

export const useGetUserSettings = () => {
  const { auction } = useAuction();
  const queryClient = useQueryClient();
  const { identity } = useIdentity();
  const principalText = identity?.getPrincipal?.().toText?.();
  const isAnonymous = !principalText || principalText === '2vxsx-fae';
  return useQuery(
    ['userSettings', principalText],
    async () => {
      try {
        return await auction.getUserSettings();
      } catch {
        return { pushNotificationsEnabled: false }
      }
    },
    {
      enabled: !isAnonymous,
      onError: (err: unknown) => {
        // do not spam toasts on initial load
        console.error('[push] getUserSettings failed', err);
        queryClient.removeQueries(['userSettings', principalText]);
      },
    });
};

export const useUpdateUserSettings = () => {
  const { auction } = useAuction();
  const queryClient = useQueryClient();
  const { enqueueSnackbar } = useSnackbar();
  const { identity } = useIdentity();
  const principalText = identity?.getPrincipal?.().toText?.();
  return useMutation(
    (pushNotificationsEnabled: boolean) =>
      auction.updateUserSettings({ pushNotificationsEnabled: [pushNotificationsEnabled] }),
    {
      onSuccess: () => {
        // Invalidate settings for the current principal only
        queryClient.invalidateQueries(['userSettings', principalText]);
      },
      onError: (err: unknown) => {
        enqueueSnackbar(`Failed to update user settings: ${err}`, { variant: 'error' });
      },
    },
  );
};

export const useWebPush = () => {
  const appCanisterId = useAuctionCanisterId();
  const { data: settings } = useGetUserSettings();
  const updateSettings = useUpdateUserSettings();
  const { enqueueSnackbar } = useSnackbar();
  const { identity } = useIdentity();

  const agentRef = useRef<HttpAgent | null>(null);
  const [client, setClient] = useState<AnyWebPushClient | null>(null);
  const [status, setStatus] = useState<PushStatus>({
    permission: Notification.permission,
    subscribed: false,
    enabledByUserSettings: false,
    effectiveEnabled: false,
  });

  // Initialize library and service worker lazily (once per static config)
  useEffect(() => {
    let cancelled = false;
    const init = async () => {
      try {
        if (!('serviceWorker' in navigator)) {
          setStatus(s => ({ ...s, lastError: 'Service workers are not supported in this browser.' }));
          return;
        }
        // Dynamic import (fail-soft if not present in some envs)
        const mod: AnyWebPushClient = await import('@research-ag/ic-web-push');
        const api: AnyWebPushClient = (mod && (mod.default ?? mod)) as AnyWebPushClient;
        if (!api) throw new Error('ic-web-push module failed to load');

        // Create agent once and reuse across identity changes
        if (!agentRef.current) {
          const agent = new HttpAgent({ identity, host: 'https://icp-api.io' });
          if (process.env.DFX_NETWORK !== 'ic') {
            try {
              await agent.fetchRootKey();
            } catch (_e) {
              // pass
            }
          }
          agentRef.current = agent;
        }

        api.init({
          agent: agentRef.current,
          applicationCanisterId: appCanisterId,
          serviceWorkerPath: SERVICE_WORKER_PATH,
          // Use the library's recommended dedicated scope to avoid conflicts
          serviceWorkerScope: '/ic-web-push/',
        });
        api.setDebug(true);

        // Register the service worker (idempotent in the library)
        await api.registerServiceWorker();

        if (cancelled) return;
        setClient(api);

        // Probe subscription status
        const subscribed = (await api.isSubscribed()) ?? false;
        const permission: NotificationPermission = Notification.permission;
        const enabledByUserSettings = !!settings?.pushNotificationsEnabled;
        setStatus({
          permission,
          subscribed,
          enabledByUserSettings,
          effectiveEnabled: subscribed && permission === 'granted' && enabledByUserSettings,
        });
      } catch (e: any) {
        console.error('[push] init error', e);
        if (!cancelled) setStatus(s => ({ ...s, lastError: String(e?.message || e) }));
      }
    };
    init();
    return () => {
      cancelled = true;
    };
    // Re-init only when the application canister ID changes
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [appCanisterId]);

  // When identity changes, update the agent's identity and refresh subscription state
  useEffect(() => {
    if (!agentRef.current || !client) return;
    try {
      // Make sure the agent uses the latest identity without re-initializing the library
      agentRef.current.invalidateIdentity?.();
      agentRef.current.replaceIdentity(identity as any);
    } catch (e) {
      console.warn('[push] Failed to replace identity on agent', e);
    }
    // Immediately clear user-settings flag to avoid showing stale state from previous principal
    setStatus(s => ({
      ...s,
      enabledByUserSettings: false,
      effectiveEnabled: s.subscribed && s.permission === 'granted' && false,
    }));
    // Refresh subscription status for the new principal
    void (async () => {
      try {
        await refreshStatus();
      } catch (_) {
      }
    })();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [identity, client]);

  const refreshStatus = async () => {
    try {
      const subscribed = (await client?.isSubscribed?.()) ?? false;
      const permission: NotificationPermission = Notification.permission;
      const enabledByUserSettings = !!settings?.pushNotificationsEnabled;
      setStatus({
        permission,
        subscribed,
        enabledByUserSettings,
        effectiveEnabled: subscribed && permission === 'granted' && enabledByUserSettings,
      });
    } catch (e: any) {
      setStatus(s => ({ ...s, lastError: String(e?.message || e) }));
    }
  };

  const enable = async () => {
    try {
      if (!client) throw new Error('Push client is not initialized yet');
      if (Notification.permission !== 'granted') {
        const p = await Notification.requestPermission();
        if (p !== 'granted') {
          setStatus(s => ({ ...s, lastError: 'Notification permission was not granted.' }));
          return;
        }
      }
      await client.subscribe?.();
      await updateSettings.mutateAsync(true);
      enqueueSnackbar('Push notifications enabled', { variant: 'success' });
      await refreshStatus();
    } catch (e: any) {
      console.error('[push] enable error', e);
      setStatus(s => ({ ...s, lastError: String(e?.message || e) }));
      enqueueSnackbar(`Failed to enable push notifications: ${String(e?.message || e)}`, { variant: 'error' });
    }
  };

  const disable = async () => {
    try {
      await client?.unsubscribe?.();
      await updateSettings.mutateAsync(false);
      enqueueSnackbar('Push notifications disabled', { variant: 'success' });
      await refreshStatus();
    } catch (e: any) {
      console.error('[push] disable error', e);
      setStatus(s => ({ ...s, lastError: String(e?.message || e) }));
      enqueueSnackbar(`Failed to disable push notifications: ${e}`, { variant: 'error' });
    }
  };

  useEffect(() => {
    const enabledByUserSettings = !!settings?.pushNotificationsEnabled;
    setStatus(s => ({
      ...s,
      enabledByUserSettings,
      effectiveEnabled: s.subscribed && s.permission === 'granted' && enabledByUserSettings,
    }));
  }, [settings?.pushNotificationsEnabled]);

  return { status, enable, disable, loading: updateSettings.isLoading };
};

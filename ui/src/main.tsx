import { useCallback, useEffect, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { Alert, AppShell, Badge, Button, Container, Group, MantineProvider, NavLink, PasswordInput, Stack, Text, Title, createTheme, useMantineColorScheme } from '@mantine/core';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { createBrowserRouter, Link, Outlet, RouterProvider, useLocation } from 'react-router-dom';
import { ApiError, ApiProvider, apiNotFoundMessage, requestApi } from './api';
import { OperationFeedback } from './components';
import { DomainsPage, RecordsPage, BlocklistsPage } from './pages/Collections';
import { OverviewPage, SettingsPage, ConfigurationPage, PolicyPage } from './pages/Management';
import { ClientsPage, RequestsPage } from './pages/Metrics';
import { BlocklistDetailsPage } from './pages/BlocklistDetails';
import { DomainInspection } from './DomainInspection';
import '@mantine/core/styles.css';
import './styles.css';
const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: 5000, refetchOnWindowFocus: false }, mutations: { retry: false } } });
const theme = createTheme({ primaryColor: 'teal', defaultRadius: 'sm', fontFamily: '"Trebuchet MS", "Verdana", sans-serif', headings: {fontFamily: '"Trebuchet MS", "Verdana", sans-serif'} });
const links = [['/', 'Overview'], ['/clients', 'Clients'], ['/requests', 'Request history'], ['/domains', 'Domains'], ['/records', 'Local records'], ['/blocklists', 'Blocklists'], ['/policy', 'Policy check'], ['/settings', 'Settings'], ['/configuration', 'Configuration']];
function Session() {
  const [key, setKey] = useState('');
  const [draft, setDraft] = useState('');
  const [loginError, setLoginError] = useState('');
  const [connecting, setConnecting] = useState(false);
  const [availability, setAvailability] = useState<'checking' | 'available' | 'unavailable'>('checking');
  const [probe, setProbe] = useState(0);
  const [mobile, setMobile] = useState(false);
  const {colorScheme, setColorScheme} = useMantineColorScheme();
  const location = useLocation();
  const logout = useCallback(() => { setKey(''); setDraft(''); queryClient.clear(); }, []);
  const unauthorized = useCallback(() => { logout(); setAvailability('available'); setLoginError('Session rejected. Enter a valid administrator API key.'); }, [logout]);
  const unavailable = useCallback(() => setAvailability('unavailable'), []);
  useEffect(() => {
    const controller = new AbortController();
    setAvailability('checking');
    async function check() {
      try {
        await requestApi('/status', '', 'GET', undefined, undefined, controller.signal);
      } catch (cause) {
        if (controller.signal.aborted) return;
        if (!(cause instanceof ApiError) || cause.code === 'ApiNotFound') {
          setAvailability('unavailable');
          return;
        }
        // An authentication rejection proves that the API is reachable.
      }
      if (controller.signal.aborted) return;
      setAvailability('available');
      void queryClient.invalidateQueries();
    }
    void check();
    return () => controller.abort();
  }, [probe]);
  const connectionNotice = availability === 'unavailable'
    ? <Alert color="red" title="API not found" role="alert"><Stack gap="sm"><Text size="sm">{apiNotFoundMessage}</Text><Button variant="default" onClick={() => setProbe(value => value + 1)}>Retry API connection</Button></Stack></Alert>
    : availability === 'checking' ? <Text role="status">Checking API connection…</Text> : null;
  async function login(event: React.FormEvent) {
    event.preventDefault(); setConnecting(true); setLoginError('');
    try {
      await requestApi('/status', draft);
      queryClient.clear(); setAvailability('available'); setKey(draft); setDraft('');
    } catch (error) {
      if (error instanceof ApiError && error.code === 'ApiNotFound') setAvailability('unavailable');
      else setLoginError(error instanceof Error ? error.message : 'Unable to connect. Try again.');
    }
    finally { setConnecting(false); }
  }
  if (!key) return <Container size={460} py={80}><Stack gap="lg"><div><Text className="eyebrow">DNS MANAGEMENT</Text><Title>VoidDNS</Title><Text c="dimmed" mt="sm">A clear view of your resolver configuration.</Text></div>{connectionNotice}{availability === 'available' ? <form onSubmit={login}><Stack><PasswordInput label="Administrator API key" description="Kept in memory for this tab only. Reloading signs you out." value={draft} onChange={event => setDraft(event.currentTarget.value)} autoComplete="off" required/>{loginError ? <Alert color="red" role="alert">{loginError}</Alert> : null}<Button type="submit" loading={connecting}>Connect</Button></Stack></form> : null}<Text size="xs" c="dimmed">Use HTTPS for remote access. This key grants full administrator privileges.</Text></Stack></Container>;
  return <ApiProvider apiKey={key} onUnauthorized={unauthorized} onUnavailable={unavailable}><AppShell header={{height: {base: 104, sm: 64}}} navbar={{width: 220, breakpoint: 'sm', collapsed: {mobile: !mobile}}} padding="lg">
    <AppShell.Header><Group h="100%" px="lg" justify="space-between"><Group><Button variant="subtle" hiddenFrom="sm" onClick={() => setMobile(!mobile)} aria-expanded={mobile}>Menu</Button><Text fw={800} size="xl">VoidDNS</Text><Badge variant="light">Management</Badge></Group><Group gap="xs"><Button size="xs" variant="subtle" onClick={() => setColorScheme(colorScheme === 'dark' ? 'light' : colorScheme === 'light' ? 'auto' : 'dark')}>Theme: {colorScheme}</Button><Button size="xs" variant="default" onClick={logout}>Sign out</Button></Group></Group></AppShell.Header>
    <AppShell.Navbar p="sm"><Stack gap={4}>{links.map(([to,label]) => <NavLink key={to} component={Link} to={to} label={label} active={location.pathname === to || (to !== '/' && location.pathname.startsWith(`${to}/`))} onClick={() => setMobile(false)}/>)}</Stack><Text size="xs" c="dimmed" mt="auto" p="sm">Exact-name filtering.<br/>Local configuration. RAM-only cache.</Text></AppShell.Navbar>
    <AppShell.Main><Container size="xl"><Stack gap="md">{connectionNotice}<OperationFeedback/><Outlet/></Stack></Container><DomainInspection/></AppShell.Main>
  </AppShell></ApiProvider>;
}
const router = createBrowserRouter([{element: <Session/>, children: [
  {index: true, element: <OverviewPage/>},
  {path: 'domains', element: <DomainsPage/>},
  {path: 'records', element: <RecordsPage/>},
  {path: 'blocklists', element: <BlocklistsPage/>},
  {path: 'blocklists/:id', element: <BlocklistDetailsPage/>},
  {path: 'settings', element: <SettingsPage/>},
  {path: 'configuration', element: <ConfigurationPage/>},
  {path: 'policy', element: <PolicyPage/>},
  {path: 'clients', element: <ClientsPage/>},
  {path: 'requests', element: <RequestsPage/>},
  {path: '*', element: <Stack><Title order={1}>Page not found</Title><Link to="/">Return to overview</Link></Stack>},
]}]);
createRoot(document.getElementById('root')!).render(<MantineProvider theme={theme} defaultColorScheme="auto"><QueryClientProvider client={queryClient}><RouterProvider router={router}/></QueryClientProvider></MantineProvider>);

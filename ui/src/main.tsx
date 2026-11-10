import { useCallback, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { Alert, AppShell, Badge, Button, Container, Group, MantineProvider, NavLink, PasswordInput, Stack, Text, Title, createTheme, useMantineColorScheme } from '@mantine/core';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { createBrowserRouter, Link, Outlet, RouterProvider, useLocation } from 'react-router-dom';
import { ApiProvider } from './api';
import { OperationFeedback } from './components';
import { DomainsPage, RecordsPage, BlocklistsPage } from './pages/Collections';
import { OverviewPage, SettingsPage, ConfigurationPage, PolicyPage } from './pages/Management';
import '@mantine/core/styles.css';
import './styles.css';
const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: 5000, refetchOnWindowFocus: false }, mutations: { retry: false } } });
const theme = createTheme({ primaryColor: 'teal', defaultRadius: 'sm', fontFamily: '"Trebuchet MS", "Verdana", sans-serif', headings: {fontFamily: '"Trebuchet MS", "Verdana", sans-serif'} });
const links = [['/', 'Overview'], ['/domains', 'Domains'], ['/records', 'Local records'], ['/blocklists', 'Blocklists'], ['/policy', 'Policy check'], ['/settings', 'Settings'], ['/configuration', 'Configuration']];
function Session() {
  const [key, setKey] = useState('');
  const [draft, setDraft] = useState('');
  const [loginError, setLoginError] = useState('');
  const [connecting, setConnecting] = useState(false);
  const [mobile, setMobile] = useState(false);
  const {colorScheme, setColorScheme} = useMantineColorScheme();
  const location = useLocation();
  const logout = useCallback(() => { setKey(''); setDraft(''); queryClient.clear(); }, []);
  const unauthorized = useCallback(() => { logout(); setLoginError('Session rejected. Enter a valid administrator API key.'); }, [logout]);
  async function login(event: React.FormEvent) {
    event.preventDefault(); setConnecting(true); setLoginError('');
    try {
      const response = await fetch('/api/v1/status', {headers: {'X-API-Key': draft}, cache: 'no-store', credentials: 'omit', redirect: 'error'});
      if (!response.ok) throw new Error(response.status === 401 ? 'Invalid API key.' : `API unavailable (${response.status}).`);
      const data = await response.json();
      if (!data?.dns || typeof data.dns.ready !== 'boolean') throw new Error('Unexpected API response. Check the same-origin proxy.');
      queryClient.clear(); setKey(draft); setDraft('');
    } catch (error) { setLoginError(error instanceof Error ? error.message : 'Unable to connect.'); }
    finally { setConnecting(false); }
  }
  if (!key) return <Container size={460} py={80}><Stack gap="lg"><div><Text className="eyebrow">DNS MANAGEMENT</Text><Title>VoidDNS</Title><Text c="dimmed" mt="sm">A clear view of your resolver configuration.</Text></div><form onSubmit={login}><Stack><PasswordInput label="Administrator API key" description="Kept in memory for this tab only. Reloading signs you out." value={draft} onChange={event => setDraft(event.currentTarget.value)} autoComplete="off" required/>{loginError ? <Alert color="red" role="alert">{loginError}</Alert> : null}<Button type="submit" loading={connecting}>Connect</Button></Stack></form><Text size="xs" c="dimmed">Use HTTPS for remote access. This key grants full administrator privileges.</Text></Stack></Container>;
  return <ApiProvider apiKey={key} onUnauthorized={unauthorized}><AppShell header={{height: {base: 104, sm: 64}}} navbar={{width: 220, breakpoint: 'sm', collapsed: {mobile: !mobile}}} padding="lg">
    <AppShell.Header><Group h="100%" px="lg" justify="space-between"><Group><Button variant="subtle" hiddenFrom="sm" onClick={() => setMobile(!mobile)} aria-expanded={mobile}>Menu</Button><Text fw={800} size="xl">VoidDNS</Text><Badge variant="light">Management</Badge></Group><Group gap="xs"><Button size="xs" variant="subtle" onClick={() => setColorScheme(colorScheme === 'dark' ? 'light' : colorScheme === 'light' ? 'auto' : 'dark')}>Theme: {colorScheme}</Button><Button size="xs" variant="default" onClick={logout}>Sign out</Button></Group></Group></AppShell.Header>
    <AppShell.Navbar p="sm"><Stack gap={4}>{links.map(([to,label]) => <NavLink key={to} component={Link} to={to} label={label} active={location.pathname === to} onClick={() => setMobile(false)}/>)}</Stack><Text size="xs" c="dimmed" mt="auto" p="sm">Exact-name filtering.<br/>Local configuration. RAM-only cache.</Text></AppShell.Navbar>
    <AppShell.Main><Container size="xl"><OperationFeedback/><Outlet/></Container></AppShell.Main>
  </AppShell></ApiProvider>;
}
const router = createBrowserRouter([{element: <Session/>, children: [
  {index: true, element: <OverviewPage/>},
  {path: 'domains', element: <DomainsPage/>},
  {path: 'records', element: <RecordsPage/>},
  {path: 'blocklists', element: <BlocklistsPage/>},
  {path: 'settings', element: <SettingsPage/>},
  {path: 'configuration', element: <ConfigurationPage/>},
  {path: 'policy', element: <PolicyPage/>},
  {path: '*', element: <Stack><Title order={1}>Page not found</Title><Link to="/">Return to overview</Link></Stack>},
]}]);
createRoot(document.getElementById('root')!).render(<MantineProvider theme={theme} defaultColorScheme="auto"><QueryClientProvider client={queryClient}><RouterProvider router={router}/></QueryClientProvider></MantineProvider>);

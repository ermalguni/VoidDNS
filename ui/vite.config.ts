import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
export default defineConfig({ plugins: [react()], server: { host: '127.0.0.1', proxy: { '/api/v1': { target: process.env.VOID_DNS_API ?? 'http://127.0.0.1:8080' } } } });

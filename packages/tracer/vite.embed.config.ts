import {defineConfig} from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  base: './',
  plugins: [react()],
  // Vite library mode leaves process.env.NODE_ENV to the consumer by default.
  // This entry is served directly to browsers and owns its production React.
  define: {'process.env.NODE_ENV': JSON.stringify('production')},
  build: {
    outDir: 'build/embed', emptyOutDir: true, target: 'es2022',
    lib: {entry: 'src/mount-publication.tsx', formats: ['es'],
      fileName: () => 'publication-workspace.mjs', cssFileName: 'workspace'},
    rolldownOptions: {output: {chunkFileNames: 'assets/[name]-[hash].mjs'}},
  },
});

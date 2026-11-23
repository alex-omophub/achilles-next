import {createRoot} from 'react-dom/client';
import {ViewerApp} from './ViewerApp';
import {PublicationView} from './PublicationView';
import './style.css';

const mode = document.querySelector('meta[name="achilles-next-mode"]')?.getAttribute('content');
const api = new URL('api/', new URL('.', window.location.href));
createRoot(document.getElementById('root')!).render(mode === 'served-publication'
  ? <PublicationView base={api}/>
  : <ViewerApp servedBase={mode === 'served-bundle' ? api : undefined}/>);

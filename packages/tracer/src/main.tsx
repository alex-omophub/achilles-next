import {createRoot} from 'react-dom/client';
import {ViewerApp} from './ViewerApp';
import './style.css';

const served = document.querySelector('meta[name="achilles-next-mode"]')?.getAttribute('content') === 'served-bundle';
const servedBase = served ? new URL('api/', new URL('.', window.location.href)) : undefined;
createRoot(document.getElementById('root')!).render(<ViewerApp servedBase={servedBase}/>);

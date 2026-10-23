import { createRoot } from 'react-dom/client'

// Worker URL + pmtiles protocol must register before any Map mounts.
import './maplibre-setup'
import { App } from './App'
import './app.css'

const root = document.getElementById('root')
if (!root) throw new Error('#root missing')

createRoot(root).render(<App />)

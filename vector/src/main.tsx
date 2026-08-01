import { createRoot } from 'react-dom/client'

import { App } from './App'
import './app.css'

const root = document.getElementById('root')
if (!root) throw new Error('#root missing')

// Avoid React StrictMode double-mount for MapLibre (map.remove + recreate races style load).
createRoot(root).render(<App />)

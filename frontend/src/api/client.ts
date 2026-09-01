import axios from 'axios';

// Same-origin '/api' works when a CDN layer stitches /api/* to the backend
// (e.g. CloudFront -> ALB on the AWS path). On a split-domain deploy
// (frontend on Cloudflare, backend on Render, no shared CDN layer) this must
// be an absolute URL, supplied at build time via VITE_API_BASE_URL.
const client = axios.create({ baseURL: import.meta.env.VITE_API_BASE_URL || '/api' });

client.interceptors.request.use((config) => {
  const token = localStorage.getItem('pp_token');
  if (token) {
    config.headers.Authorization = `Bearer ${token}`;
  }
  return config;
});

client.interceptors.response.use(
  (response) => response,
  (error) => {
    if (error.response?.status === 401) {
      localStorage.removeItem('pp_token');
      localStorage.removeItem('pp_user_id');
      window.location.href = '/login';
    }
    return Promise.reject(error);
  },
);

export default client;

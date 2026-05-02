// Put your global types here

declare module "*.svg" {
  const content: string;
  export default content;
}

declare module "*.png" {
  const content: string;
  export default content;
}

declare module "*.jpg" {
  const content: string;
  export default content;
}

//* A common return type from SteamClient functions.
type Unregisterer = {
  unregister: () => void;
}

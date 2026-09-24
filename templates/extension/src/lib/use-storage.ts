import * as React from "react"

/**
 * useState backed by chrome.storage.local, kept in sync across the side panel,
 * popup, options page and service worker.
 */
export function useStorage<T>(key: string, initialValue: T) {
  const [value, setValue] = React.useState<T>(initialValue)

  React.useEffect(() => {
    chrome.storage.local.get(key).then((items) => {
      if (key in items) setValue(items[key] as T)
    })

    const handleChange = (
      changes: Record<string, chrome.storage.StorageChange>,
      area: string
    ) => {
      if (area === "local" && key in changes) {
        setValue(changes[key].newValue as T)
      }
    }
    chrome.storage.onChanged.addListener(handleChange)
    return () => chrome.storage.onChanged.removeListener(handleChange)
  }, [key])

  const update = React.useCallback(
    (next: T) => {
      setValue(next)
      void chrome.storage.local.set({ [key]: next })
    },
    [key]
  )

  return [value, update] as const
}

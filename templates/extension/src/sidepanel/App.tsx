import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import {
  Card,
  CardContent,
  CardDescription,
  CardFooter,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import {
  Field,
  FieldContent,
  FieldDescription,
  FieldGroup,
  FieldLabel,
} from "@/components/ui/field"
import { Switch } from "@/components/ui/switch"
import { useTheme } from "@/components/theme-provider"
import { useStorage } from "@/lib/use-storage"
import { MoonIcon, SunIcon } from "lucide-react"

const { name, version } = chrome.runtime.getManifest()

export function App() {
  const [enabled, setEnabled] = useStorage("enabled", true)
  const { theme, setTheme } = useTheme()
  const isDark =
    theme === "dark" ||
    (theme === "system" &&
      window.matchMedia("(prefers-color-scheme: dark)").matches)

  return (
    <main className="flex min-h-svh flex-col gap-4 p-4">
      <Card>
        <CardHeader>
          <CardTitle className="flex items-center gap-2">
            {name}
            <Badge variant="secondary">v{version}</Badge>
          </CardTitle>
          <CardDescription>
            Edit src/sidepanel/App.tsx to build your side panel.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <FieldGroup>
            <Field orientation="horizontal">
              <FieldContent>
                <FieldLabel htmlFor="enabled">Enabled</FieldLabel>
                <FieldDescription>
                  Saved in chrome.storage, so it survives restarts.
                </FieldDescription>
              </FieldContent>
              <Switch
                id="enabled"
                checked={enabled}
                onCheckedChange={setEnabled}
              />
            </Field>
          </FieldGroup>
        </CardContent>
        <CardFooter>
          <Button
            variant="outline"
            onClick={() => setTheme(isDark ? "light" : "dark")}
          >
            {isDark ? (
              <SunIcon data-icon="inline-start" />
            ) : (
              <MoonIcon data-icon="inline-start" />
            )}
            {isDark ? "Light mode" : "Dark mode"}
          </Button>
        </CardFooter>
      </Card>
    </main>
  )
}

export default App

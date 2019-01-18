# TestchainBackend


## Deployment service

```elixir
iex(6)> Proxy.Deployment.BaseApi.request("test", "get_info")
{:error,
 %{
   "code" => "notFound",
   "detail" => "Unknown method: get_info",
   "errorList" => []
 }}
iex(7)> Proxy.Deployment.BaseApi.request("test", "GetInfo")
{:ok,
 %{
   "result" => %{
     "steps" => [
       %{
         "defaults" => %{"osmDelay" => "1"},
         "description" => "Step 7 - MS 3 - Crash & Bite",
         "id" => 1,
         "oracles" => [
           %{"contract" => "MEDIANIZER_ETH", "symbol" => "ETH"},
           %{"contract" => "MEDIANIZER_REP", "symbol" => "REP"}
         ],
         "roles" => ["CREATOR", "CDP_OWNER"]
       }
     ],
     "tagHash" => "f1e23cd2aecb42ddb74f29eb7db576f21b1911d9"
   },
   "type" => "ok"
 }}
```



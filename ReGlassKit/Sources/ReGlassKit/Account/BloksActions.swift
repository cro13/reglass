import Foundation

// The `bk.action.*` opcodes the interpreter hands off to the session: navigation, tree edits, platform facts,
// timers, animations, and login completion. Scope is account selection and email codes only — no other-app
// credential reads, no password collection, no consent bypass, and no silent skipping of unsupported auth actions.
extension BloksSession {
    func action(_ screen: Screen?, _ ctx: BloksContext, _ name: String, _ args: [Any?]) throws -> Any? {
        guard !done else { return nil }
        func x(_ i: Int) -> Any? { args.at(i) }
        func str(_ i: Int) -> String { x(i) as? String ?? "" }
        func num(_ i: Int) -> Int { bint(x(i)) }
        func node(_ i: Int) -> BloksNode? { x(i) as? BloksNode }
        func map(_ i: Int) -> BloksMap { x(i) as? BloksMap ?? BloksMap() }
        func list(_ i: Int) -> [Any?] { blist(x(i)) }
        @discardableResult func cb(_ fn: Any?, _ a: [Any?] = []) throws -> Any? { guard fn is BloksLambda else { return nil }; return try interpreter.call(fn, a) }
        let parentPayload = (ctx as? Nested)?.payload ?? screen?.payload
        func instance(_ id: String, _ vars: BloksMap? = nil) throws -> Instance {
            guard let payload = parentPayload?.embedded[id] ?? screen?.payload.embedded[id] else { throw BloksError("Missing embedded login payload") }
            let nested = screen?.instances["payload:" + id] ?? Nested(self, payload, screen, ctx)
            screen?.instances["payload:" + id] = nested
            try declare(payload, nested)
            for (key, value) in vars?.pairs ?? [] { if screen?.vars[bstr(key)] == nil { screen?.vars[bstr(key)] = value ?? NSNull() } }
            return Instance(payload, nested)
        }
        func container(_ id: Any?, parent: Bool = false) -> BloksNode? {
            guard let screen, let root = screen.payload.tree else { return nil }
            return find(screen, root, bstr(id), parent: parent)
        }
        func edit(_ n: BloksNode?, _ change: ([Any?]) -> [Any?]) {
            guard let n, let screen else { return }
            screen.children[ObjectIdentifier(n)] = change(screen.childrenOf(n))
        }
        func legacy(_ appId: String, _ params: BloksMap, _ name: String?) throws {
            let payload = BloksMap()
            if let value = params.get("params") { payload.set("params", bstr(value)) }
            let sent = try BloksJson.encode(payload)
            request(.screen(appId, sent), then: { try self.push(appId, $0, params); self.screens.last?.name = name })
        }
        switch name {
        case "bk.action.bloks.GetVariable2", "bk.action.bloks.GetVariableWithScope": return variable(screen, str(0))
        case "bk.action.bloks.WriteLocalState": if let key = screen?.globalKeys[str(0)] { globals[key] = x(1) ?? NSNull() } else { screen?.vars[str(0)] = x(1) ?? NSNull() }; return nil
        case "bk.action.bloks.WriteGlobalConsistencyStore": globals[str(0)] = x(1) ?? NSNull(); return nil
        case "bk.action.bloks.UpdateGlobalConsistencyStore": globals[str(0)] = try cb(x(1), [globals[str(0)]]) ?? NSNull(); return nil
        case "bk.action.bloks.GetScript": return try ctx.script(str(0))
        case "bk.action.bloks.GetParameter": return screen?.params.get(x(0))
        case "bk.action.bloks.asynccomponents.GetClientParamV2": return (ctx as? Nested)?.clientParam(bstr(x(0)))
        case "bk.action.core.GetTemplateArg": return (ctx as? Nested)?.templateArg(str(0)) ?? (ctx as? Nested)?.templateArg(String(str(0).drop(while: { $0 == "_" })))
        case "bk.action.bloks.GetPayload": return try instance(str(0), x(1) as? BloksMap)
        case "bk.action.bloks.ParseHoistedPayload": return try instance(str(0))
        case "bk.action.bloks.ParseEmbedded":
            let text = str(0); let json = try BloksJson.decode(text) as? BloksMap
            let payload = try BloksPayload.parse(json?.has("layout") == true ? text : json?.get("payload") as? String ?? "")
            let nested = Nested(self, payload, screen, ctx); try declare(payload, nested); return Instance(payload, nested)
        case "bk.action.template.Make":
            let payload: BloksPayload
            if let instance = x(0) as? Instance { payload = instance.payload }
            else if let embedded = parentPayload?.embedded[str(0)] ?? screen?.payload.embedded[str(0)] { payload = embedded }
            else if let tree = parentPayload?.templates[str(0)] ?? screen?.payload.templates[str(0)], let holder = parentPayload { payload = holder.withTree(tree) }
            else { throw BloksError("Missing login template") }
            let key = "template:\(ObjectIdentifier(payload)):\(bstr(x(2)))"
            let nested = screen?.instances[key] ?? Nested(self, payload, screen, ctx, map(1)); screen?.instances[key] = nested
            nested.templateArgs = map(1); try declare(payload, nested); return Instance(payload, nested)
        case "bk.action.bloks.GetValue":
            let id = str(0); if let cached = screen?.values[id] { return cached is NSNull ? nil : cached }
            guard let script = parentPayload?.values[id] ?? screen?.payload.values[id] else { throw BloksError("Missing login value") }
            let value = try interpreter.run(script.expr(), ctx); screen?.values[id] = value ?? NSNull(); return value
        case "bk.action.const.Get": let value = parentPayload?.constants[str(0)] ?? screen?.payload.constants[str(0)]; return value is NSNull ? nil : value
        case "bk.action.bloks.WithScope": return try cb(x(0))
        case "bk.action.bloks.Reduce": return nil
        case "bk.action.tree.Make": var attrs: [Int: Any] = [:]; for i in stride(from: 1, to: max(1, args.count - 1), by: 2) { attrs[bint(args[i])] = args[i + 1] ?? NSNull() }; return BloksNode(num(0), attrs)
        case "bk.action.ref.Make": return BloksRef(x(0))
        case "bk.action.ref.Read": return (x(0) as? BloksRef)?.value
        case "bk.action.ref.Write": (x(0) as? BloksRef)?.value = x(1); return nil
        case "bk.action.context.Get": return screen
        case "bk.action.callback.Make", "bk.action.callback.MakeWithScopeOnly": return x(0)
        case "bk.action.callback.Apply": return try cb(x(0), Array(args.dropFirst()))
        case "bk.action.textinput.GetText": guard let n = node(0), !Interpreter.truthy(n[99]) else { return nil }; return text(screen, n)
        case "bk.action.textinput.GetSensitiveText": return node(0).map { text(screen, $0) }
        case "bk.action.textinput.SetTextV2": if let n = node(0) { screen?.texts[ObjectIdentifier(n)] = x(1).map(bstr) ?? "" }; return nil
        case "bk.action.text_input.ClearText": if let n = node(0) { screen?.texts[ObjectIdentifier(n)] = "" }; return nil
        case "bk.action.text_input.AppendText", "bk.action.text_input.InsertTextAtCursor": if let n = node(0) { screen?.texts[ObjectIdentifier(n)] = text(screen, n) + (x(1).map(bstr) ?? "") }; return nil
        case "bk.action.text_input.KeyboardEventBackspace": if let n = node(0) { screen?.texts[ObjectIdentifier(n)] = String(text(screen, n).dropLast(max(0, num(1)))) }; return nil
        case "bk.action.textinput.GetSelectionStart", "bk.action.textinput.GetSelectionEnd": return node(0).map { Int32(text(screen, $0).utf16.count) }
        case "bk.action.bloks.DismissKeyboard", "bk.action.bloks.ClearFocus": focus = nil; dismissCount += 1; return nil
        case "bk.action.bloks.ShowKeyboard", "bk.action.bloks.RequestFocus": focus = node(0); return focus != nil
        case "bk.action.bloks.AsyncActionWithDataManifestV2":
            let appId = str(0), callbacks = node(2), props = try cb(callbacks?[40]) as? BloksMap, params = try bflat(x(1))
            request(.action(appId, params), then: { payload in
                try self.runAction(payload, screen, props); try cb(callbacks?[36], [nil, screen])
            }, failed: {
                guard callbacks?[35] is BloksLambda else { throw BloksError("Native login request failed (response withheld).") }
                try cb(callbacks?[35], [screen])
            })
            return nil
        case "bk.action.bloks.AsyncActionWithDataManifest":
            let appId = str(0), params = "{" + map(1).pairs.map { bstr($0.0) + ":" + bstr($0.1) + "," }.joined() + "}"
            request(.action(appId, params), then: { payload in try self.runAction(payload, screen, nil); try cb(x(2), [nil, screen]) },
                    failed: { guard x(3) is BloksLambda else { throw BloksError("Native login request failed (response withheld).") }; try cb(x(3)) })
            return nil
        case "bk.action.bloks.ReadPandoField": return map(0).get(x(1))
        case "bk.action.dialog.OpenDialog":
            guard let d = node(0) else { throw BloksError("Invalid dialog") }
            let buttons = [38, 44, 36].compactMap { key -> BloksDialog.Button? in guard let b = d[key] as? BloksNode else { return nil }; return .init(label: b[36] as? String ?? "OK", handler: b[35] as? BloksLambda) }
            dialog = BloksDialog(title: d[40] as? String, message: d[35] as? String, buttons: buttons); return nil
        case "bk.action.toast.ShowToastV2":
            if let instance = x(0) as? Instance, let tree = instance.payload.tree, let screen {
                let builder = UiBuilder(interpreter: interpreter, screen: screen, dark: true, text: { self.text(screen, $0) })
                let ui = try builder.build(tree, instance.ctx)
                message = Flat.of(ui).items.compactMap { switch $0 { case .heading(let s), .paragraph(let s, _, _): return s; default: return nil } }.joined(separator: " ")
            }
            return nil
        case "bk.action.toast.DismissToast": message = nil; return nil
        case "bk.mt.action.DeliverOidcAuthCode":
            guard !str(0).isEmpty, str(2) == metaRedirectURI, str(3) == "934401142814369" else { throw BloksError("Native login returned a code for an unexpected client.") }
            finish(.code(str(0))); return nil
        case "bk.fx.action.CompleteMetaLogin", "bk.action.mwa.CompleteFRLLoginWithCallback":
            guard !str(0).isEmpty else { throw BloksError("Native login returned an empty token.") }
            finish(.token(str(0))); return nil
        case "bk.action.mma.CompleteTokenExchangeV2":
            guard let text = node(0)?[41] as? String, let auth = try BloksJson.decode(text) as? BloksMap, let token = auth.get("access_token") as? String, !token.isEmpty else { throw BloksError("Native login returned no account token.") }
            finish(.token(token)); return nil

        // Tree overlays: preserve the server's selection/callback state, not a hard-coded list of accounts.
        case "bk.action.bloks.Find", "bk.action.bloks.FindContainer": return container(x(0))
        case "bk.action.bloks.ChildAtIndex": return node(0).flatMap { screen?.childrenOf($0).at(num(1)) }
        case "bk.action.bloks.IndexOfChild": return node(0).map { n in Int32(screen?.childrenOf(n).firstIndex { ($0 as? BloksNode)?[33].map(bstr) == bstr(x(1)) } ?? -1) } ?? -1
        case "bk.action.bloks.OneTimeBind": return x(0)
        case "bk.action.bloks.Inflate", "bk.action.bloks.InflateSync":
            let text = try BloksJson.encode(x(0)); let object = try JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)
            let n = try BloksPayload.convert(object) as? BloksNode
            if name.hasSuffix("Sync") { return n }; try cb(n == nil ? x(2) : x(1), n.map { [$0] } ?? []); return nil
        case "bk.action.bloks.AppendChildren", "bk.action.bloks.AppendEmbeddedChildren": edit(container(x(0))) { $0 + list(1) }; return nil
        case "bk.action.bloks.PrependChildren", "bk.action.bloks.PrependEmbeddedChildren": edit(container(x(0))) { list(1) + $0 }; return nil
        case "bk.action.bloks.ReplaceChildren": edit(container(x(0))) { _ in list(1) }; return nil
        case "bk.action.bloks.ReplaceEmbeddedChildren": screen?.replaced[bstr(x(0))] = list(1); return nil
        case "bk.action.bloks.ReplaceChild", "bk.action.bloks.ReplaceEmbeddedChildV2", "bk.action.bloks.ReplaceChildrenAfter", "bk.action.bloks.ReplaceEmbeddedChildrenAfter", "bk.action.bloks.InsertChildrenAfter", "bk.action.bloks.InsertEmbeddedChildrenAfter", "bk.action.bloks.InsertChildrenBefore", "bk.action.bloks.InsertEmbeddedChildrenBefore":
            let id = bstr(x(2)); edit(container(id, parent: true)) { kids in
                guard let i = kids.firstIndex(where: { ($0 as? BloksNode)?[33].map(bstr) == id }) else { return kids }
                if name.contains("Before") { return Array(kids.prefix(i)) + list(1) + Array(kids.dropFirst(i)) }
                if name.contains("Insert") { return Array(kids.prefix(i + 1)) + list(1) + Array(kids.dropFirst(i + 1)) }
                if name.contains("After") { return Array(kids.prefix(i + 1)) + list(1) }
                return Array(kids.prefix(i)) + list(1) + Array(kids.dropFirst(i + 1))
            }
            return nil
        case "bk.action.bloks.RemoveChild": let id = bstr(x(1)); edit(container(id, parent: true)) { $0.filter { ($0 as? BloksNode)?[33].map(bstr) != id } }; return nil
        case "bk.action.bloks.RemoveChildrenBetween": edit(node(0)) { kids in guard let a = kids.firstIndex(where: { ($0 as? BloksNode)?[33].map(bstr) == bstr(x(1)) }), let b = kids.firstIndex(where: { ($0 as? BloksNode)?[33].map(bstr) == bstr(x(2)) }), a <= b else { return kids }; return Array(kids.prefix(a + 1)) + Array(kids.dropFirst(b)) }; return nil
        case "bk.action.component.SetAttr": if let n = node(0), let key = str(1).utf16.first { screen?.attrs[ObjectIdentifier(n), default: [:]][Int(key)] = x(2) ?? NSNull() }; return nil
        case "bk.action.component.GetHeight", "bk.action.component.GetWidth": return nil
        case "bk.action.component.GetHeight2", "bk.action.component.GetWidth2": return Int32(0)
        case "bk.action.screen.Open":
            let params = node(0)?[38] as? BloksMap ?? BloksMap()
            guard let appId = params.get("__infra__app_id") as? String else { throw BloksError("Missing screen app id") }
            let query = try BloksJson.encode(BloksMap([("params", BloksMap([("__infra__container_config_id", params.get("__infra__container_config_id") ?? Int32(16542))]))]))
            request(.component(appId, query), then: { try self.push(appId, $0, params) }); return nil
        case "bk.action.cds.OpenScreen", "bk.action.cds.PushScreen", "bk.action.cds.OpenCdsBottomSheet", "bk.action.cds.PushCdsBottomSheet":
            guard let appId = node(0)?[35] as? String else { throw BloksError("Missing screen app id") }
            let params = map(2), sent = try bflat(params), dismiss = name.contains(".Open") ? node(1)?[40] as? BloksLambda : nil
            request(.screen(appId, sent), then: { try self.push(appId, $0, params); self.screens.last?.onClose = dismiss }); return nil
        case "bk.action.bloks.OpenScreen": try legacy(str(0), map(1), nil); return nil
        case "bk.action.bloks.OpenFullScreenV2", "bk.action.bloks.OpenFullScreenV4": guard let d = node(0), let app = d[35] as? String else { throw BloksError("Missing screen app id") }; try legacy(app, map(1), (d[45] ?? d[40]).map(bstr)); return nil
        case "bk.action.bloks.CloseScreenV2", "bk.action.navigation.CloseScreen", "ig.action.navigation.CloseScreen":
            if let target = node(0)?[35].map(bstr), let i = screens.lastIndex(where: { $0.name == target }) { let count = screens.count - i + (Interpreter.truthy(node(0)?[36]) ? 1 : 0); for _ in 0..<count { if !done { try pop() } } } else { try pop() }; return nil
        case "bk.action.cds.CloseScreen", "bk.action.cds.DismissCdsBottomSheet": while !screens.isEmpty && !done { try pop() }; if !done { try cb(node(0)?[35]) }; return nil
        case "bk.action.cds.PopCdsBottomSheet", "bk.action.screen.Close": try pop(); return nil
        case "bk.action.cds.internal.RemoveCdsBottomSheet": if let i = screens.lastIndex(where: { bstr($0.params.get("__infra__screen_id") ?? $0.params.get("INTERNAL_INFRA_screen_id")) == bstr(x(0)) }) { if i == screens.count - 1 { try pop() } else { screens.remove(at: i).clear() } }; return nil
        case "bk.action.cds.UpdateBackButtonOverride": screen?.backOverride = x(0) as? BloksLambda; return nil
        case "bk.action.bloks.OpenBottomSheetV2", "bk.action.bloks.PushBottomSheetV2": guard let instance = x(0) as? Instance, let root = instance.payload.tree, let content = root[35] as? BloksNode else { throw BloksError("Missing sheet content") }; try push(name, instance.payload.withTree(content), BloksMap()); screens.last?.title = root[36] as? String; screens.last?.onClose = root[38] as? BloksLambda; return nil
        case "bk.action.bloks.DismissBottomSheet": while screens.last?.appId.hasSuffix("BottomSheetV2") == true && !done { try pop() }; return nil
        case "bk.action.text.GetText": return node(0)?[41] as? String
        case "bk.action.text.IsTruncated": return false
        case "bk.action.text.GetMeasuredLayout": return list(0).isEmpty ? nil : BloksMap([("lineCount", Int32(1)), ("overflowed", false)])
        case "bk.action.string.FromProvider": if let n = node(0), n.type == 13950 { return n[36].map(bstr) ?? "0" }; return ""

        // Platform values for the sign-in schema.
        case "bk.action.caa.login.GetUniqueDeviceId", "bk.fx.action.GetFamilyDeviceId", "bk.action.mwa.payments.GetDeviceID": return deviceID
        case "bk.action.caa.FetchMachineID": return Self.machineID
        case "bk.action.device.GetDeviceOSVersion": return Int32(35)
        case "bk.action.mwa.IsDarkModeEnabled": return true
        case "bk.action.accessibility.GetFontScale": return 1.0
        case "bk.action.accessibility.GetScreenDensity": return Int32(420)
        case "bk.action.accessibility.IsScreenReaderEnabled", "bk.action.accessibility.IsReduceMotionEnabled", "bk.action.accessibility.IsHighContrastEnabled", "bk.action.accessibility.IsGreyscaleEnabled": return false
        case "bk.action.caa.GetWaterfallId": return ""
        case "bk.action.session_store.Get": return sessionStore
        case "bk.action.frl.SetIDForAYMH": prefs.set("id_for_aymh", x(0)); return nil
        case "bk.action.frl.GetDBLData": return prefs.get("dbl_data") as? String ?? ""
        case "bk.action.frl.SetDBLData": prefs.set("dbl_data", x(0).map(bstr) ?? ""); return nil
        case "bk.action.frl.GetCategoryCount": let entry = prefs.get("category:" + bstr(x(0))) as? BloksArray; return bnum(entry?.items.at(1)) < Date().timeIntervalSince1970 * 1000 ? Int32(0) : entry?.items.at(0) ?? Int32(0)
        case "bk.action.frl.IncreaseCategoryCount": let key = "category:" + bstr(x(0)), entry = prefs.get(key) as? BloksArray, count = bnum(entry?.items.at(1)) < Date().timeIntervalSince1970 * 1000 ? 1 : bint(entry?.items.at(0)) + 1; prefs.set(key, BloksArray([Int32(count), x(1)])); return Int32(count)
        case "bk.action.core.Delay": later(num(0)) { try cb(x(1), [screen]) }; return nil
        case "bk.action.dispatch.GetMainQueue": return "main"
        case "bk.action.dispatch.GetLowPriBackgroundQueue": return "background"
        case "bk.action.DispatchAsync": later(1) { try cb(x(1)) }; return nil
        case "bk.action.timer.Start":
            let id = bstr(x(4)); timers[id]?.task?.cancel()
            guard timers.count < 32 else { throw BloksError("Login timer limit") }
            let timer = BloksTimer(id, max(100, num(1)), Interpreter.truthy(x(2)), x(3), screen); timers[id] = timer; schedule(timer); return nil
        case "bk.action.timer.Stop": if let timer = timers[bstr(x(0))] { timer.stopped = true; timer.task?.cancel() }; return nil
        case "bk.action.timer.Restart": if let timer = timers[bstr(x(0))] { timer.task?.cancel(); timer.stopped = false; schedule(timer) }; return nil
        case "bk.action.timer.Cancel": timers.removeValue(forKey: bstr(x(1) ?? x(0)))?.task?.cancel(); return nil
        case "bk.action.animated.Create", "bk.action.animated.CreateDimension", "bk.action.animated.CreateColor", "bk.action.animation.linear.CreateAnimation": return BloksAnimation(x(2), x(3), x(0), x(1), linear: name.contains("linear"))
        case "bk.action.animated.CreateSpring": return BloksAnimation(Int32(0), Int32(1), x(0), nil)
        case "bk.action.animated.Build": if let animation = x(0) as? BloksAnimation { animations[bstr(x(1))] = animation }; return x(0)
        case "bk.action.animated.StartToken": if let animation = animations[bstr(x(0))] { try finishAnimation(animation, screen) }; return nil
        case "bk.action.animated.Start", "bk.action.animation.linear.Start", "bk.action.animated.StartWithToken": if let animation = x(0) as? BloksAnimation { if name.hasSuffix("WithToken") { animations[bstr(x(1))] = animation }; try finishAnimation(animation, screen) }; return nil
        case "bk.action.animation.linear.SetNewEndValue": if let animation = x(0) as? BloksAnimation { animation.to = x(1); animation.done = false; try finishAnimation(animation, screen) }; return nil
        case "bk.action.animated.AddOnCompleteListener": if let animation = x(0) as? BloksAnimation { animation.listeners.append(x(1)) }; return x(0)
        case "bk.action.animated.Parallel", "bk.action.animated.Sequence", "bk.action.animated.Stagger", "bk.action.animated.cds.UpdateBottomSheet", "bk.action.animated.CreateSharedElementV3": let animation = BloksAnimation(nil, nil, nil, name.hasSuffix("Parallel") ? x(0) : nil); animation.children = list(name.hasSuffix("Parallel") ? 2 : name.hasSuffix("Stagger") ? 1 : 0).compactMap { $0 as? BloksAnimation }; return animation
        case "bk.action.animated.Loop": return x(1) as? BloksAnimation
        case "bk.action.animated.GetCurrentValue", "bk.action.animation.linear.GetCurrentValue": return (x(0) as? BloksAnimation)?.value
        case "bk.action.animated.GetCurrentDimensionValue", "bk.action.animated.GetCurrentColorValue": return (x(0) as? BloksAnimation)?.value.map(bstr)
        case "bk.action.animated.ToAnimator": return x(0)
        case "bk.action.animated.IsInitialized": return animations[bstr(x(0))] != nil
        case "bk.action.animated.Destroy": animations.removeValue(forKey: bstr(x(0))); return nil
        case "bk.action.animated.Pause", "bk.action.animated.Resume": return false
        case "bk.action.animated.GetTotalDuration", "bk.action.animated.GetCurrentPlayTime": return 0.0
        case "bk.action.io.Toast": message = x(0) as? String; return nil
        case "bk.action.slv.FWAToast": message = node(0)?[45] as? String; return nil

        // Return truthful "unavailable" outcomes, so Meta offers typed email + emailed code instead of Android SSO.
        case "bk.action.caa.FoaFetchOpenIdTokens": try cb(x(0), [BloksMap()]); return nil
        case "bk.fx.action.FetchAllAvailableNativeAuthDataForCaller", "bk.fx.action.FetchAllAvailableNativeAuthData": try cb(x(2), [BloksArray()]); return nil
        case "bk.fx.action.FetchNativeAuthDataWithFeatureSupport": try cb(x(4), [BloksArray()]); return nil
        case "bk.action.caa.login.FetchCredentialManager": try cb(x(1), ["no_account_selected", "", "", "", "", ""]); return nil
        case "bk.action.caa.login.SaveCredential": try cb(x(4)); return nil
        case "bk.action.caa.FetchSMSCode": try cb(x(1), [nil, "error", screen]); return nil
        case "bk.action.caa.reg.FetchSMSCodeFromRetriever": return ""
        case "bk.action.bloks.IsAppInstalled", "bk.action.caa.ShouldAcceptOxygenPreloadTos", "bk.action.caa.ShouldShowExplicitOxygenPreloadTos": return false
        case "bk.action.caa.login.RemoveProfile": prefs.remove("dbl_data"); try cb(x(3), [screen]); return nil
        case "bk.action.caa.reg.LogoutCurrentUser": sessionStore.pairs.removeAll(); try cb(x(1), ["SUCCESS", ""]); return nil
        case "bk.action.frl.FetchAndSaveAccountsCenterCookie": throw BloksError("Meta requested an Accounts Center cookie handoff that this native flow does not support.")
        case "bk.action.fx.passkey.CheckDeviceEligibility": return "credential_manager_unavailable"
        case "bk.action.fx.passkey.CreatePasskey": if let n = node(0) { if n[42] != nil { try cb(n[42], ["Passkeys are unavailable in ReGlass"]) } else { try cb(n[41]) } }; return nil
        case "bk.action.fx.passkey.UsePasskey":
            if let n = node(0), n[44] != nil { if n[43] != nil { try cb(n[43], [BloksMap([("error_type", "android.credentials.GetCredentialException.TYPE_NO_CREDENTIAL"), ("error_message", "No credentials available"), ("exception_class", "androidx.credentials.exceptions.NoCredentialException")])]); try cb(n[52]) } else { try cb(n[41]) } }; return nil
        case "bk.action.fx.passkey.SignalAllAcceptedCredentials", "bk.action.fx.passkey.SignalCurrentUserDetails", "bk.action.fx.passkey.SignalUnknownCredential": try cb(node(0)?[38], [Int32(0), "Credential Manager unavailable"]); return nil
        case "bk.fx.action.HideInitialLoadingState": try cb(x(0)); return nil
        case "bk.fx.action.UpdateClientLinkageCache", "bk.fx.action.UpdateClientServiceCache": try cb(x(1)); return nil
        case "bk.fx.action.ExitLinkingFlow", "bk.fx.action.TriggerLinkingFlowCallbackV2": finish(.cancelled); return nil
        case "bk.action.mft.security.GetDeviceKeys": return BloksArray()
        case "bk.action.age.GetOsAgeRange": later(1) { try cb(x(1), [screen, "API_NOT_AVAILABLE"]) }; return nil
        case "bk.action.mft.security.mfa.IsFactorAvailable", "bk.action.mft.security.mfa.UseFactor": try cb(node(0)?[36], [name.hasSuffix("IsFactorAvailable") ? false : nil, "Factors not available"]); return nil
        case "bk.action.mft.ModularCreateAuthenticationTicket": try cb(x(6), [BloksMap([("error_message", "unsupported"), ("exception", ""), ("error_code", Int32(0))])]); return nil
        case "bk.action.mft.ModularGeneratePTT": try cb(x(11), [BloksMap([("exception", ""), ("error_code", Int32(0)), ("error_message", "unsupported"), ("remaining_attempts", nil), ("auth_factor_expired", false)])]); return nil
        case "bk.action.caa.reg.GetAgeFromBirthdayTimestamp": let born = Date(timeIntervalSince1970: bnum(x(0))); return Int32(Calendar.current.dateComponents([.year], from: born, to: Date()).year ?? 0)
        case "bk.action.textspan.GetCenterX", "bk.action.textspan.GetCenterY", "bk.action.textspan.GetHeight", "bk.action.textspan.GetWidth": return Int32(0)
        case "bk.action.collection.GetVisibleCollectionItemAt": return BloksMap()
        case "bk.action.hcollection.GetOffset", "bk.action.vcollection.GetOffset", "bk.action.keyframes.GetProgress", "bk.action.video.GetPositionV2", "bk.action.visibility_context.GetTimeSinceLastImpressionInMS": return Int32(0)
        case "bk.action.keyframes.IsPlaying", "bk.action.video.GetIsMutedV2", "bk.action.visibility_context.HasSeenBefore": return false
        case "bk.action.video.GetPlaybackStateV3": return "unprepared"
        case "bk.action.visibility_context.PercentVisible": return 1.0
        case "bk.action.cds.internal.GetContainerMode": return nil
        default:
            if Self.noOpActions.contains(name) || name.hasPrefix("bk.action.qpl.") || name.hasPrefix("bk.action.ttrc.") || name.hasPrefix("bk.action.trace.") || name.hasPrefix("bk.action.versioning.") { return nil }
            // Only the known function name is diagnostic. Never stringify args, scripts, or server errors.
            throw BloksError("Unsupported native login action: \(name). Login stopped; no enrollment attempted.")
        }
    }

    func schedule(_ timer: BloksTimer) {
        let id = timer.id
        let interval = min(timer.interval, 3_600_000)
        timer.task = Task { [weak self, weak timer] in
            try? await Task.sleep(for: .milliseconds(interval))
            guard let self, let timer, !Task.isCancelled, !timer.stopped, self.timers[id] === timer else { return }
            self.apply {
                if let screen = timer.screen, !self.screens.contains(where: { $0 === screen }) { self.timers[id] = nil; return }
                if let callback = timer.callback as? BloksLambda { _ = try self.interpreter.call(callback, [id, timer.screen]) }
                if timer.repeats && !timer.stopped && self.timers[id] === timer { self.schedule(timer) } else { self.timers[id] = nil }
            }
        }
    }

    func finishAnimation(_ animation: BloksAnimation, _ screen: Screen?) throws {
        guard !animation.done else { return }
        animation.done = true
        animation.value = animation.to
        if let update = animation.update as? BloksLambda { _ = try interpreter.call(update, [animation]) }
        for child in animation.children { try finishAnimation(child, screen) }
        for listener in animation.listeners.compactMap({ $0 as? BloksLambda }) { _ = try interpreter.call(listener, animation.linear ? [animation] : [animation, false, screen]) }
    }

    static let noOpActions: Set<String> = [
        "bk.action.logging.LogEvent", "bk.action.debug.internal.DeviceLogV2", "bk.action.errorreporting.ReportError",
        "bk.action.HapticFeedback", "bk.action.SetAppCanSleep", "bk.action.SetBlockScreenshot", // iOS has no FLAG_SECURE; the sheet masks itself in the background.
        "bk.action.accessibility.SetFocus", "bk.action.accessibility.Announcement", "bk.action.animated.easing.CreateCubicBezier",
        "bk.action.animated.Cancel", "bk.action.animated.CancelToken", "bk.action.animated.CancelWithToken", "bk.action.animated.SetCurrentPlayTime", "bk.action.animation.linear.Cancel",
        "bk.action.bloks.FetchAsyncComponents", "bk.action.bloks.ClearCachedAsyncComponents", "bk.action.bloks.InvalidateCachedAsyncComponents", "bk.action.AsyncComponentCacheWrite", "bk.action.bloks.MarkerAnnotateAsyncComponentResponse", "bk.action.bloks.pando.PublishGraphQLJSON",
        "bk.action.cds.UpdateBottomSheet", "bk.action.cds.UpdateModalContainer", "bk.action.screen.EnableChainedNavigation", "bk.action.screen.DisableChainedNavigation",
        "bk.action.pando.CreateRawTreeUpdater", "bk.action.pando.CreateTreeUpdater", "bk.action.pando.MaybeUpdateActiveFields", "bk.action.pando.PublishTreeUpdater",
        "bk.action.caa.StartSMSCodeRetriever", "bk.action.caa.ClearSMSCode", "bk.action.CompleteAllLoginDiagnosis", "bk.action.FRXEndFlowEvent", "bk.fx.action.LoadingOverlay",
        "bk.action.collection.SetIndex", "bk.action.collection.SetIndexById", "bk.action.collection.ScrollToIndexById", "bk.action.hcollection.SetOffset", "bk.action.vcollection.SetOffset", "bk.action.tooltip.Show", "bk.action.tooltip.Hide",
    ]
}

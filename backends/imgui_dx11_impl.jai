// This file is an attempt to be a faithful recreation of the original imgui 
// backend file(https://github.com/ocornut/imgui/blob/master/backends/imgui_impl_dx11.cpp)
// in Jai. It is mostly syntax changes, but there are a few things that needed to be 
// changed to fit the Jai way of doing things.
//

ImGui_ImplDX11_Data :: struct {
    pd3dDevice: *ID3D11Device;
    pd3dDeviceContext: *ID3D11DeviceContext;
    pFactory: *IDXGIFactory;
    pVB: *ID3D11Buffer;
    pIB: *ID3D11Buffer;
    pVertexShader: *ID3D11VertexShader;
    pInputLayout: *ID3D11InputLayout;
    pVertexConstantBuffer: *ID3D11Buffer;
    pPixelShader: *ID3D11PixelShader;
    pFontSampler: *ID3D11SamplerState;
    pFontTextureView: *ID3D11ShaderResourceView;
    pRasterizerState: *ID3D11RasterizerState;
    pBlendState: *ID3D11BlendState;
    pDepthStencilState: *ID3D11DepthStencilState;
    VertexBufferSize: s32 = 5000;
    IndexBufferSize: s32 = 10000;
}

VERTEX_CONSTANT_BUFFER_DX11 :: struct {
    mvp: [4][4] float;
}

ImDrawCallback_ResetRenderState :: (draw_list: *ImGui.ImDrawList, draw_cmd: *ImGui.ImDrawCmd) #c_call {
    /* 
     * This is here to act as a signal value for the renderer.
     * If a user wants the renderer to reset the render state,
     * in C++'s ImGui you could set the UserCallback to -1.
     * However, Jai does not support casting interger values
     * as function pointers. So Instead use this function for
     * your UserCallback for that same behavior.
     */
}

ImGui_ImplDX11_RenderDrawData :: (draw_data: *ImGui.ImDrawData) {
    // Avoid rendering when minimized
    if draw_data.DisplaySize.x <= 0.0 || draw_data.DisplaySize.y <= 0.0
        return;

    bd  := ImGui_ImplDX11_GetBackendData();
    ctx := bd.pd3dDeviceContext;

    // Create and grow vertex/index buffers if needed
    if !bd.pVB || bd.VertexBufferSize < draw_data.TotalVtxCount {
        if bd.pVB {
            IUnknown_Release(bd.pVB);
            bd.pVB = null;
        }

        bd.VertexBufferSize = draw_data.TotalVtxCount + 5000;
        using desc: D3D11_BUFFER_DESC;
        Usage = .D3D11_USAGE_DYNAMIC;
        ByteWidth = xx (bd.VertexBufferSize * size_of(ImGui.ImDrawVert));
        BindFlags = .D3D11_BIND_VERTEX_BUFFER;
        CPUAccessFlags = .D3D11_CPU_ACCESS_WRITE;
        MiscFlags = 0;
        if ID3D11Device_CreateBuffer(bd.pd3dDevice, *desc, null, *bd.pVB) < 0
            return;
    }
    if !bd.pIB || bd.IndexBufferSize < draw_data.TotalIdxCount {
        if bd.pIB {
            IUnknown_Release(bd.pIB);
            bd.pIB = null;
        }
        bd.IndexBufferSize = draw_data.TotalIdxCount + 10000;
        using desc: D3D11_BUFFER_DESC;
        Usage = .D3D11_USAGE_DYNAMIC;
        ByteWidth = xx (bd.IndexBufferSize * size_of(ImGui.ImDrawIdx));
        BindFlags = .D3D11_BIND_INDEX_BUFFER;
        CPUAccessFlags = .D3D11_CPU_ACCESS_WRITE;
        if ID3D11Device_CreateBuffer(bd.pd3dDevice, *desc, null, *bd.pIB) < 0
            return;
    }

    // Upload vertex/index data into a single contiguous GPU buffer
    vtx_resource: D3D11_MAPPED_SUBRESOURCE;
    idx_resource: D3D11_MAPPED_SUBRESOURCE;
    if ID3D11DeviceContext_Map(ctx, bd.pVB, 0, .D3D11_MAP_WRITE_DISCARD, 0, *vtx_resource) != S_OK
        return;
    if ID3D11DeviceContext_Map(ctx, bd.pIB, 0, .D3D11_MAP_WRITE_DISCARD, 0, *idx_resource) != S_OK
        return;
    vtx_dst := cast(*ImGui.ImDrawVert)vtx_resource.pData;
    idx_dst := cast(*ImGui.ImDrawIdx) idx_resource.pData;
    for n : 0..draw_data.CmdListsCount-1 { // -1 because Jai for loops are inclusive on both ends
        cmd_list: *ImGui.ImDrawList = draw_data.CmdLists[n];
        memcpy(vtx_dst, cmd_list.VtxBuffer.Data, cmd_list.VtxBuffer.Size * size_of(ImGui.ImDrawVert));
        memcpy(idx_dst, cmd_list.IdxBuffer.Data, cmd_list.IdxBuffer.Size * size_of(ImGui.ImDrawIdx));
        vtx_dst += cmd_list.VtxBuffer.Size;
        idx_dst += cmd_list.IdxBuffer.Size;
    }
    ID3D11DeviceContext_Unmap(ctx, bd.pVB, 0);
    ID3D11DeviceContext_Unmap(ctx, bd.pIB, 0);

    // Setup orthographic projection matrix into ou constant buffer
    // Our visible imgui space lies from draw_data->DisplayPos (top left) to draw_data->DisplayPos+data_data->DisplaySize (bottom right). DisplayPos is (0,0) for single viewport apps.
    {
        mapped_resource: D3D11_MAPPED_SUBRESOURCE;
        if ID3D11DeviceContext_Map(ctx, bd.pVertexConstantBuffer, 0, .D3D11_MAP_WRITE_DISCARD, 0, *mapped_resource) != S_OK
            return;

        constant_buffer := cast(*VERTEX_CONSTANT_BUFFER_DX11)mapped_resource.pData;
        L := draw_data.DisplayPos.x;
        R := draw_data.DisplayPos.x + draw_data.DisplaySize.x;
        T := draw_data.DisplayPos.y;
        B := draw_data.DisplayPos.y + draw_data.DisplaySize.y;
        mvp: [4][4] float = .[
            .[ 2.0/(R-L),   0.0,         0.0, 0.0 ],
            .[ 0.0,         2.0/(T-B),   0.0, 0.0 ],
            .[ 0.0,         0.0,         0.5, 0.0 ],
            .[ (R+L)/(L-R), (T+B)/(B-T), 0.5, 1.0 ],
        ];
        memcpy(*constant_buffer.mvp, mvp.data, 16 * 4); // TODO(Steven): I don't think this is working as expected...
        ID3D11DeviceContext_Unmap(ctx, bd.pVertexConstantBuffer, 0);
    }

    // Backup DX state tat will be modified to restore it afterwards (unfortunetly this is very ugly looking and verbose. Close your eyes!)
    BACKUP_DX11_STATE :: struct {
        ScissorRectsCount: u32;
        ViewportsCount: u32;
        ScissorRects: [D3D11_VIEWPORT_AND_SCISSORRECT_OBJECT_COUNT_PER_PIPELINE] D3D11_RECT;
        Viewports: [D3D11_VIEWPORT_AND_SCISSORRECT_OBJECT_COUNT_PER_PIPELINE] D3D11_VIEWPORT;
        RS: *ID3D11RasterizerState;
        BlendState: *ID3D11BlendState;
        BlendFactor: [4] float;
        SampleMask: u32;
        StencilRef: u32;
        DepthStencilState: *ID3D11DepthStencilState;
        PSShaderResource: *ID3D11ShaderResourceView;
        PSSampler: *ID3D11SamplerState;
        PS: *ID3D11PixelShader;
        VS: *ID3D11VertexShader;
        GS: *ID3D11GeometryShader;
        PSInstancesCount: u32;
        VSInstancesCount: u32;
        GSInstancesCount: u32;
        PSInstances: [256] *ID3D11ClassInstance; // 256 is max according to PSSetShader documentation
        VSInstances: [256] *ID3D11ClassInstance; //
        GSInstances: [256] *ID3D11ClassInstance; //
        PrimitiveTopology: D3D11_PRIMITIVE_TOPOLOGY;
        IndexBuffer: *ID3D11Buffer;
        VertexBuffer: *ID3D11Buffer;
        VSConstantBuffer: *ID3D11Buffer;
        IndexBufferOffset: u32;
        VertexBufferStride: u32;
        VertexBufferOffset: u32;
        IndexBufferFormat: DXGI_FORMAT;
        InputLayout: *ID3D11InputLayout;
    }
    old: BACKUP_DX11_STATE;
    old.ScissorRectsCount = D3D11_VIEWPORT_AND_SCISSORRECT_OBJECT_COUNT_PER_PIPELINE;
    old.ViewportsCount = D3D11_VIEWPORT_AND_SCISSORRECT_OBJECT_COUNT_PER_PIPELINE;
    ID3D11DeviceContext_RSGetScissorRects(ctx, *old.ScissorRectsCount, old.ScissorRects.data);
    ID3D11DeviceContext_RSGetViewports(ctx, *old.ViewportsCount, old.Viewports.data);
    ID3D11DeviceContext_RSGetState(ctx, *old.RS);
    ID3D11DeviceContext_OMGetBlendState(ctx, *old.BlendState, *old.BlendFactor, *old.SampleMask);
    ID3D11DeviceContext_OMGetDepthStencilState(ctx, *old.DepthStencilState, *old.StencilRef);
    ID3D11DeviceContext_PSGetShaderResources(ctx, 0, 1, *old.PSShaderResource);
    ID3D11DeviceContext_PSGetSamplers(ctx, 0, 1, *old.PSSampler);
    old.PSInstancesCount = 256;
    old.VSInstancesCount = 256;
    old.GSInstancesCount = 256;
    ID3D11DeviceContext_PSGetShader(ctx, *old.PS, old.PSInstances.data, *old.PSInstancesCount);
    ID3D11DeviceContext_VSGetShader(ctx, *old.VS, old.VSInstances.data, *old.VSInstancesCount);
    ID3D11DeviceContext_VSGetConstantBuffers(ctx, 0, 1, *old.VSConstantBuffer);
    ID3D11DeviceContext_GSGetShader(ctx, *old.GS, old.GSInstances.data, *old.GSInstancesCount);

    ID3D11DeviceContext_IAGetPrimitiveTopology(ctx, *old.PrimitiveTopology);
    ID3D11DeviceContext_IAGetIndexBuffer(ctx, *old.IndexBuffer, *old.IndexBufferFormat, *old.IndexBufferOffset);
    ID3D11DeviceContext_IAGetVertexBuffers(ctx, 0, 1, *old.VertexBuffer, *old.VertexBufferStride, *old.VertexBufferOffset);
    ID3D11DeviceContext_IAGetInputLayout(ctx, *old.InputLayout);

    // Setup desired DX state
    ImGui_ImplDX11_SetupRenderState(draw_data, ctx);

    // Render command lists
    // (Because we merged all buffers into a single one, we maintain our own offset into them)
    global_idx_offset: s32 = 0;
    global_vtx_offset: s32 = 0;
    clip_off := draw_data.DisplayPos;
    for n : 0..draw_data.CmdListsCount-1 { // -1 because Jai for loops are inclusive on both ends
        cmd_list := draw_data.CmdLists[n];
        for cmd_i : 0..cmd_list.CmdBuffer.Size-1 { // -1 because Jai for loops are inclusive on both ends
            pcmd := cmd_list.CmdBuffer.Data + cmd_i;
            if pcmd.UserCallback != null {
                // User callback, registered via ImDrawList::AddCallback()
                // (ImDrawCallback_ResetRenderState is a special callback value used by the user to request the renderer to reset render state.)
                if pcmd.UserCallback == ImDrawCallback_ResetRenderState
                    ImGui_ImplDX11_SetupRenderState(draw_data, ctx);
                else
                    pcmd.UserCallback(cmd_list, pcmd);
            }
            else {
                // Project scissor/clipping rectangles into framebuffer space
                clip_min := ImGui.ImVec2.{ pcmd.ClipRect.x - clip_off.x, pcmd.ClipRect.y - clip_off.y };
                clip_max := ImGui.ImVec2.{ pcmd.ClipRect.z - clip_off.x, pcmd.ClipRect.w - clip_off.y };
                if clip_max.x <= clip_min.x || clip_max.y <= clip_min.y
                    continue;
                
                // Apply scissor/clipping rectangle
                r := D3D11_RECT.{ cast(s32)clip_min.x, cast(s32)clip_min.y, cast(s32)clip_max.x, cast(s32)clip_max.y };
                ID3D11DeviceContext_RSSetScissorRects(ctx, 1, *r);

                // Bind texture, Draw
                texture_srv := cast(*ID3D11ShaderResourceView)pcmd.TextureId;
                ID3D11DeviceContext_PSSetShaderResources(ctx, 0, 1, *texture_srv);
                ID3D11DeviceContext_DrawIndexed(ctx, pcmd.ElemCount, pcmd.IdxOffset + (cast(u32)global_idx_offset), cast(s32)(pcmd.VtxOffset + (cast(u32)global_vtx_offset)));
            }
        }
        global_idx_offset += cmd_list.IdxBuffer.Size;
        global_vtx_offset += cmd_list.VtxBuffer.Size;
    }

    // Restore modified DX state
    ID3D11DeviceContext_RSSetScissorRects(ctx, old.ScissorRectsCount, old.ScissorRects.data);
    ID3D11DeviceContext_RSSetViewports(ctx, old.ViewportsCount, old.Viewports.data);
    ID3D11DeviceContext_RSSetState(ctx, old.RS); if old.RS then IUnknown_Release(old.RS);
    ID3D11DeviceContext_OMSetBlendState(ctx, old.BlendState, *old.BlendFactor, old.SampleMask); if old.BlendState then IUnknown_Release(old.BlendState);
    ID3D11DeviceContext_OMSetDepthStencilState(ctx, old.DepthStencilState, old.StencilRef); if old.DepthStencilState then IUnknown_Release(old.DepthStencilState);
    ID3D11DeviceContext_PSSetShaderResources(ctx, 0, 1, *old.PSShaderResource); if old.PSShaderResource then IUnknown_Release(old.PSShaderResource);
    ID3D11DeviceContext_PSSetSamplers(ctx, 0, 1, *old.PSSampler); if old.PSSampler then IUnknown_Release(old.PSSampler);
    ID3D11DeviceContext_PSSetShader(ctx, old.PS, old.PSInstances.data, old.PSInstancesCount); if old.PS then IUnknown_Release(old.PS);
    for old.PSInstances {
        if old.PSInstances[it_index] then IUnknown_Release(old.PSInstances[it_index]);
    }
    ID3D11DeviceContext_VSSetShader(ctx, old.VS, old.VSInstances.data, old.VSInstancesCount); if old.VS then IUnknown_Release(old.VS);
    ID3D11DeviceContext_VSSetConstantBuffers(ctx, 0, 1, *old.VSConstantBuffer); if old.VSConstantBuffer then IUnknown_Release(old.VSConstantBuffer);
    ID3D11DeviceContext_GSSetShader(ctx, old.GS, old.GSInstances.data, old.GSInstancesCount); if old.GS then IUnknown_Release(old.GS);
    for old.VSInstances {
        if old.VSInstances[it_index] then IUnknown_Release(old.VSInstances[it_index]);
    }
    ID3D11DeviceContext_IASetPrimitiveTopology(ctx, old.PrimitiveTopology);
    ID3D11DeviceContext_IASetIndexBuffer(ctx, old.IndexBuffer, old.IndexBufferFormat, old.IndexBufferOffset); if old.IndexBuffer then IUnknown_Release(old.IndexBuffer);
    ID3D11DeviceContext_IASetVertexBuffers(ctx, 0, 1, *old.VertexBuffer, *old.VertexBufferStride, *old.VertexBufferOffset); if old.VertexBuffer then IUnknown_Release(old.VertexBuffer);
    ID3D11DeviceContext_IASetInputLayout(ctx, old.InputLayout); if old.InputLayout then IUnknown_Release(old.InputLayout);
}

ImGui_ImplDX11_CreateDeviceObjects :: () -> bool {
    bd := ImGui_ImplDX11_GetBackendData();
    if !bd.pd3dDevice
        return false;
    if bd.pFontSampler
        ImGui_ImplDX11_InvalidateDeviceObjects();

    // By using D3DCompile() from <d3dcompiler.h> / d3dcompiler.lib, we introduce a dependency to a given version of d3dcompiler_XX.dll (see D3DCOMPILER_DLL_A)
    // If you would like to use this DX11 sample code but remove this dependency you can:
    //  1) compile once, save the compiled shader blobs into a file or source code and pass them to CreateVertexShader()/CreatePixelShader() [preferred solution]
    //  2) use code to detect any version of the DLL and grab a pointer to D3DCompile from the DLL.
    // See https://github.com/ocornut/imgui/pull/638 for sources and details.

    // Create the vertex shader
    {
        vertexShader :: #string END
cbuffer vertexBuffer : register(b0)
{
    float4x4 ProjectionMatrix;
};

struct VS_INPUT
{
    float2 pos : POSITION;
    float4 col : COLOR0;
    float2 uv  : TEXCOORD0;
};

struct PS_INPUT
{
    float4 pos : SV_POSITION;
    float4 col : COLOR0;
    float2 uv  : TEXCOORD0;
};

PS_INPUT main(VS_INPUT input)
{
    PS_INPUT output;
    output.pos = mul( ProjectionMatrix, float4(input.pos.xy, 0.f, 1.f));
    output.col = input.col;
    output.uv  = input.uv;
    return output;
}
END

        vertexShaderBlob: *ID3DBlob;
        if FAILED(D3DCompile(vertexShader.data, vertexShader.count, null, null, null, "main", "vs_4_0", 0, 0, *vertexShaderBlob, null)) {
            return false; // NB: Pass ID3DBlob* pErrorBlob to D3DCompile() to get error showing in (const char*)pErrorBlob->GetBufferPointer(). Make sure to Release() the blob!
        }
        if ID3D11Device_CreateVertexShader(bd.pd3dDevice, ID3D10Blob_GetBufferPointer(vertexShaderBlob), ID3D10Blob_GetBufferSize(vertexShaderBlob), null, *bd.pVertexShader) != S_OK {
            IUnknown_Release(vertexShaderBlob);
            return false;
        }

        // Create the input layout
        pos_offset :: #run offset_of(ImGui.ImDrawVert, "pos");
        uv_offset  :: #run offset_of(ImGui.ImDrawVert, "uv");
        col_offset :: #run offset_of(ImGui.ImDrawVert, "col");
        local_layout: [] D3D11_INPUT_ELEMENT_DESC = .[
            .{ "POSITION", 0, .DXGI_FORMAT_R32G32_FLOAT,   0, pos_offset, .D3D11_INPUT_PER_VERTEX_DATA, 0 },
            .{ "TEXCOORD", 0, .DXGI_FORMAT_R32G32_FLOAT,   0, uv_offset,  .D3D11_INPUT_PER_VERTEX_DATA, 0 },
            .{ "COLOR",    0, .DXGI_FORMAT_R8G8B8A8_UNORM, 0, col_offset, .D3D11_INPUT_PER_VERTEX_DATA, 0 },
        ];
        if ID3D11Device_CreateInputLayout(bd.pd3dDevice, local_layout.data, xx local_layout.count, ID3D10Blob_GetBufferPointer(vertexShaderBlob), ID3D10Blob_GetBufferSize(vertexShaderBlob), *bd.pInputLayout) != S_OK {
            IUnknown_Release(vertexShaderBlob);
            return false;
        }
        IUnknown_Release(vertexShaderBlob);

        // Create the constant buffer
        {
            using desc: D3D11_BUFFER_DESC;
            ByteWidth = size_of(VERTEX_CONSTANT_BUFFER_DX11);
            Usage = .D3D11_USAGE_DYNAMIC;
            BindFlags = .D3D11_BIND_CONSTANT_BUFFER;
            CPUAccessFlags = .D3D11_CPU_ACCESS_WRITE;
            MiscFlags = 0;
            ID3D11Device_CreateBuffer(bd.pd3dDevice, *desc, null, *bd.pVertexConstantBuffer);
        }
    }

    // Create pixel shader
    {
        pixelShader :: #string END
struct PS_INPUT
{
    float4 pos : SV_POSITION;
    float4 col : COLOR0;
    float2 uv  : TEXCOORD0;
};
sampler sampler0;
Texture2D texture0;

float4 main(PS_INPUT input) : SV_Target
{
    float4 out_col = input.col * texture0.Sample(sampler0, input.uv);
    return out_col;
}
END
        pixelShaderBlob: *ID3DBlob;
        if FAILED(D3DCompile(pixelShader.data, pixelShader.count, null, null, null, "main", "ps_4_0", 0, 0, *pixelShaderBlob, null)) {
            return false; // NB: Pass ID3DBlob* pErrorBlob to D3DCompile() to get error showing in (const char*)pErrorBlob->GetBufferPointer(). Make sure to Release() the blob!
        }
        if ID3D11Device_CreatePixelShader(bd.pd3dDevice, ID3D10Blob_GetBufferPointer(pixelShaderBlob), ID3D10Blob_GetBufferSize(pixelShaderBlob), null, *bd.pPixelShader) != S_OK {
            IUnknown_Release(pixelShaderBlob);
            return false;
        }
        IUnknown_Release(pixelShaderBlob);
    }

    // Create the blending setup
    {
        using desc: D3D11_BLEND_DESC;
        AlphaToCoverageEnable = 0;
        RenderTarget[0].BlendEnable = 1;
        RenderTarget[0].SrcBlend = .D3D11_BLEND_SRC_ALPHA;
        RenderTarget[0].DestBlend = .D3D11_BLEND_INV_SRC_ALPHA;
        RenderTarget[0].BlendOp = .D3D11_BLEND_OP_ADD;
        RenderTarget[0].SrcBlendAlpha = .D3D11_BLEND_ONE;
        RenderTarget[0].DestBlendAlpha = .D3D11_BLEND_INV_SRC_ALPHA;
        RenderTarget[0].BlendOpAlpha = .D3D11_BLEND_OP_ADD;
        RenderTarget[0].RenderTargetWriteMask = xx D3D11_COLOR_WRITE_ENABLE.D3D11_COLOR_WRITE_ENABLE_ALL;
        ID3D11Device_CreateBlendState(bd.pd3dDevice, *desc, *bd.pBlendState);
    }

    // Create the rasterizer state
    {
        using desc: D3D11_RASTERIZER_DESC;
        FillMode = .D3D11_FILL_SOLID;
        CullMode = .D3D11_CULL_NONE;
        ScissorEnable = 1;
        DepthClipEnable = 1;
        ID3D11Device_CreateRasterizerState(bd.pd3dDevice, *desc, *bd.pRasterizerState);
    }

    // Create depth-stencil State
    {
        using desc: D3D11_DEPTH_STENCIL_DESC;
        DepthEnable = 0;
        DepthWriteMask = .D3D11_DEPTH_WRITE_MASK_ALL;
        DepthFunc = .D3D11_COMPARISON_ALWAYS;
        StencilEnable = 0;
        FrontFace.StencilFailOp = .D3D11_STENCIL_OP_KEEP;
        FrontFace.StencilDepthFailOp = .D3D11_STENCIL_OP_KEEP;
        FrontFace.StencilPassOp = .D3D11_STENCIL_OP_KEEP;
        FrontFace.StencilFunc = .D3D11_COMPARISON_ALWAYS;
        BackFace = FrontFace;
        ID3D11Device_CreateDepthStencilState(bd.pd3dDevice, *desc, *bd.pDepthStencilState);
    }

    ImGui_ImplDX11_CreateFontsTexture();

    return true;
}

ImGui_ImplDX11_InvalidateDeviceObjects :: () {
    bd := ImGui_ImplDX11_GetBackendData();
    if !bd.pd3dDevice
        return;

    if bd.pFontSampler           { IUnknown_Release(bd.pFontSampler); bd.pFontSampler = null; }
    if bd.pFontTextureView       { IUnknown_Release(bd.pFontTextureView); bd.pFontTextureView = null; ImGui.GetIO().Fonts.TexID = null; } // We copied data->pFontTextureView to io.Fonts->TexID so let's clear that as well. // NOTE(Steven): The setting of TexID was changed from SetTexID(0) to Fonts.TexID = 0. For some reason, the method does not exist. So lets see if this works!
    if bd.pIB                    { IUnknown_Release(bd.pIB); bd.pIB = null; }
    if bd.pVB                    { IUnknown_Release(bd.pVB); bd.pVB = null; }
    if bd.pBlendState            { IUnknown_Release(bd.pBlendState); bd.pBlendState = null; }
    if bd.pDepthStencilState     { IUnknown_Release(bd.pDepthStencilState); bd.pDepthStencilState = null; }
    if bd.pRasterizerState       { IUnknown_Release(bd.pRasterizerState); bd.pRasterizerState = null; }
    if bd.pPixelShader           { IUnknown_Release(bd.pPixelShader); bd.pPixelShader = null; }
    if bd.pVertexConstantBuffer  { IUnknown_Release(bd.pVertexConstantBuffer); bd.pVertexConstantBuffer = null; }
    if bd.pInputLayout           { IUnknown_Release(bd.pInputLayout); bd.pInputLayout = null; }
    if bd.pVertexShader          { IUnknown_Release(bd.pVertexShader); bd.pVertexShader = null; }
}

ImGui_ImplDX11_Init :: (device: *ID3D11Device, device_context: *ID3D11DeviceContext) -> bool {
    io := ImGui.GetIO();
    assert(io.BackendRendererUserData == null, "Already initialized a renderer backend!");

    // Setup backend capabilites flags
    bd : *ImGui_ImplDX11_Data = alloc(size_of(ImGui_ImplDX11_Data));
    io.BackendRendererUserData = cast(*void)bd;
    io.BackendRendererName = "imgui_impl_dx11_jai";
    io.BackendFlags_ |= .ImGuiBackendFlags_RendererHasVtxOffset; // We honor the ImDrawCmd::VtxOffset field, allowing for large meshes.
    io.BackendFlags_ |= .ImGuiBackendFlags_RendererHasViewports; // We can create mutli-viewports on the Renderer side (optional)

    // Get factory from device
    pDXGIDevice: *IDXGIDevice;
    pDXGIAdapter: *IDXGIAdapter;
    pFactory: *IDXGIFactory;

    if IUnknown_QueryInterface(device, *uid(IDXGIDevice_UUID), cast(**void)*pDXGIDevice) == S_OK {
        if IDXGIObject_GetParent(pDXGIDevice, *uid(IDXGIAdapter_UUID), cast(**void)*pDXGIAdapter) == S_OK {
            if IDXGIObject_GetParent(pDXGIAdapter, *uid(IDXGIFactory_UUID), cast(**void)*pFactory) == S_OK {
                bd.pd3dDevice = device;
                bd.pd3dDeviceContext = device_context;
                bd.pFactory = pFactory;
            }
        }
    }
    if pDXGIDevice  IUnknown_Release(pDXGIDevice);
    if pDXGIAdapter IUnknown_Release(pDXGIAdapter);
    IUnknown_AddRef(bd.pd3dDevice);
    IUnknown_AddRef(bd.pd3dDeviceContext);

    if io.ConfigFlags_ & .ImGuiConfigFlags_ViewportsEnable
        ImGui_ImplDX11_InitPlatformInterface();

    return true;
}

ImGui_ImplDX11_Shutdown :: () {
    bd := ImGui_ImplDX11_GetBackendData();
    assert(bd != null, "No renderer backend to shutdown, or already shutdown?");
    io := ImGui.GetIO();

    ImGui_ImplDX11_ShutdownPlatformInterface();
    ImGui_ImplDX11_InvalidateDeviceObjects();
    if (bd.pFactory)           IUnknown_Release(bd.pFactory);
    if (bd.pd3dDevice)         IUnknown_Release(bd.pd3dDevice);
    if (bd.pd3dDeviceContext)  IUnknown_Release(bd.pd3dDeviceContext);
    io.BackendRendererName = null;
    io.BackendRendererUserData = null;
    io.BackendFlags_ &= ~(.ImGuiBackendFlags_RendererHasVtxOffset | .ImGuiBackendFlags_RendererHasViewports);

    if bd {
        free(bd);
        bd = null;
    }
}

ImGui_ImplDX11_NewFrame :: () {
    bd := ImGui_ImplDX11_GetBackendData();
    assert(bd != null, "Did you call ImGui_ImplDX11_Init()?");

    if !bd.pFontSampler
        ImGui_ImplDX11_CreateDeviceObjects();
}


#scope_file
ImGui_ImplDX11_GetBackendData :: () -> *ImGui_ImplDX11_Data #c_call {
    return ifx ImGui.GetCurrentContext() then ImGui.GetIO().BackendRendererUserData else null;
}

ImGui_ImplDX11_SetupRenderState :: (draw_data: *ImGui.ImDrawData, ctx: *ID3D11DeviceContext) {
    bd := ImGui_ImplDX11_GetBackendData();

    // Setup Viewport
    {
        using vp: D3D11_VIEWPORT;
        Width = draw_data.DisplaySize.x;
        Height = draw_data.DisplaySize.y;
        MinDepth = 0.0;
        MaxDepth = 1.0;
        vp.TopLeftX = 0;
        vp.TopLeftY = 0;
        ID3D11DeviceContext_RSSetViewports(ctx, 1, *vp);
    }

    // Setup shader and vertex buffers
    {
        stride: u32 = size_of(ImGui.ImDrawVert);
        offset: u32;

        ID3D11DeviceContext_IASetInputLayout(ctx, bd.pInputLayout);
        ID3D11DeviceContext_IASetVertexBuffers(ctx, 0, 1, *bd.pVB, *stride, *offset);
        ID3D11DeviceContext_IASetIndexBuffer(ctx, bd.pIB, ifx size_of(ImGui.ImDrawIdx) == 2 then .DXGI_FORMAT_R16_UINT else .DXGI_FORMAT_R32_UINT, 0);
        ID3D11DeviceContext_IASetPrimitiveTopology(ctx, .D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        ID3D11DeviceContext_VSSetShader(ctx, bd.pVertexShader, null, 0);
        ID3D11DeviceContext_VSSetConstantBuffers(ctx, 0, 1, *bd.pVertexConstantBuffer);
        ID3D11DeviceContext_PSSetShader(ctx, bd.pPixelShader, null, 0);
        ID3D11DeviceContext_PSSetSamplers(ctx, 0, 1, *bd.pFontSampler);
        ID3D11DeviceContext_GSSetShader(ctx, null, null, 0);
        ID3D11DeviceContext_HSSetShader(ctx, null, null, 0); // In theory we should backup and restore this as well.. very infrequently used..
        ID3D11DeviceContext_DSSetShader(ctx, null, null, 0); // In theory we should backup and restore this as well.. very infrequently used..
        ID3D11DeviceContext_CSSetShader(ctx, null, null, 0); // In theory we should backup and restore this as well.. very infrequently used..
    }

    // Setup blend state
    {
        blend_factor : [4] float : .[ 0.0, 0.0, 0.0, 0.0 ];
        ID3D11DeviceContext_OMSetBlendState(ctx, bd.pBlendState, *blend_factor, 0xffffffff);
        ID3D11DeviceContext_OMSetDepthStencilState(ctx, bd.pDepthStencilState, 0);
        ID3D11DeviceContext_RSSetState(ctx, bd.pRasterizerState);
    }
}

ImGui_ImplDX11_CreateFontsTexture :: () {
    io := ImGui.GetIO();
    bd := ImGui_ImplDX11_GetBackendData();
    pixels: *u8;
    width: s32;
    height: s32;
    io.Fonts.GetTexDataAsRGBA32(io.Fonts, *pixels, *width, *height);

    // Upload texture to graphics system
    {
        using desc: D3D11_TEXTURE2D_DESC;
        Width = xx width;
        Height = xx height;
        MipLevels = 1;
        ArraySize = 1;
        Format = .DXGI_FORMAT_R8G8B8A8_UNORM;
        SampleDesc.Count = 1;
        Usage = .DEFAULT;
        BindFlags = .D3D11_BIND_SHADER_RESOURCE;
        CPUAccessFlags = 0;

        pTexture: *ID3D11Texture2D;
        subResource: D3D11_SUBRESOURCE_DATA;
        subResource.pSysMem = pixels;
        subResource.SysMemPitch = desc.Width * 4;
        subResource.SysMemSlicePitch = 0;
        ID3D11Device_CreateTexture2D(bd.pd3dDevice, *desc, *subResource, *pTexture);
        assert(pTexture != null);

        // Create texture view
        srvDesc: D3D11_SHADER_RESOURCE_VIEW_DESC;
        srvDesc.Format = .DXGI_FORMAT_R8G8B8A8_UNORM;
        srvDesc.ViewDimension = .D3D11_SRV_DIMENSION_TEXTURE2D;
        srvDesc.Texture2D.MipLevels = desc.MipLevels;
        srvDesc.Texture2D.MostDetailedMip = 0;
        ID3D11Device_CreateShaderResourceView(bd.pd3dDevice, pTexture, *srvDesc, *bd.pFontTextureView);
        IUnknown_Release(pTexture);
    }

    // Store our identifier
    io.Fonts.TexID = bd.pFontTextureView; // NOTE(Steven): Change SetTexID() to just assigning the TexID. Becuase the SetTexID method does not existing for some reason...

    // Create texture sampler
    // (Bilinear sampling is required by default. Set 'io.Fonts->Flags |= ImFontAtlasFlags_NoBakedLines' or 'style.AntiAliasedLinesUseTex = false' to allow point/nearest sampling)
    {
        using desc: D3D11_SAMPLER_DESC;
        Filter = .D3D11_FILTER_MIN_MAG_MIP_LINEAR;
        AddressU = .D3D11_TEXTURE_ADDRESS_WRAP;
        AddressV = .D3D11_TEXTURE_ADDRESS_WRAP;
        AddressW = .D3D11_TEXTURE_ADDRESS_WRAP;
        MipLODBias = 0.0;
        ComparisonFunc = .D3D11_COMPARISON_ALWAYS;
        MinLOD = 0.0;
        MaxLOD = 0.0;
        ID3D11Device_CreateSamplerState(bd.pd3dDevice, *desc, *bd.pFontSampler);
    }
}


// Multi-Viewport stuff
ImGui_ImplDX11_ViewportData :: struct {
    SwapChain: *IDXGISwapChain;
    RTView: *ID3D11RenderTargetView;
}

ImGui_ImplDX11_CreateWindow :: (viewport: *ImGui.Viewport) #c_call {
    ctx: Context;
    push_context ctx {
        bd := ImGui_ImplDX11_GetBackendData();
        vd := cast(*ImGui_ImplDX11_ViewportData)alloc(size_of(ImGui_ImplDX11_ViewportData));
        memset(vd, 0, size_of(ImGui_ImplDX11_ViewportData)); // clear the memory at the allocated location? why does this seem not to already be cleared by alloc?
        viewport.RendererUserData = vd;

        // PlatformHandleRaw should always be a HWND, whereas PlatformHandle might be a higher-level handle (e.g. GLFWWindow*, SDL_Window*).
        // Some backends will leave PlatformHandleRaw == 0, in which case we assume PlatformHandle will contain the HWND.
        hwnd: HWND = ifx viewport.PlatformHandleRaw then cast(HWND)viewport.PlatformHandleRaw else cast(HWND)viewport.PlatformHandle;
        assert(hwnd != null);

        // Create swap chain
        using sd: DXGI_SWAP_CHAIN_DESC;
        BufferDesc.Width   = cast(u32)viewport.Size.x;
        BufferDesc.Height  = cast(u32)viewport.Size.y;
        BufferDesc.Format  = .DXGI_FORMAT_R8G8B8A8_UNORM;
        SampleDesc.Count   = 1;
        SampleDesc.Quality = 0;
        BufferUsage        = .DXGI_USAGE_RENDER_TARGET_OUTPUT;
        BufferCount        = 1;
        OutputWindow       = hwnd;
        Windowed           = 1; // True
        SwapEffect         = .DXGI_SWAP_EFFECT_DISCARD;
        Flags              = 0;

        assert(vd.SwapChain == null && vd.RTView == null);
        IDXGIFactory_CreateSwapChain(bd.pFactory, bd.pd3dDevice, *sd, *vd.SwapChain);

        // Create the render target
        if vd.SwapChain {
            pBackBuffer: *ID3D11Texture2D;
            IDXGISwapChain_GetBuffer(vd.SwapChain, 0, *uid(ID3D11Texture2D_UUID), cast(**void)*pBackBuffer);
            ID3D11Device_CreateRenderTargetView(bd.pd3dDevice, pBackBuffer, null, *vd.RTView);
            IUnknown_Release(pBackBuffer);
        }
    }
}

ImGui_ImplDX11_DestroyWindow :: (viewport: *ImGui.Viewport) #c_call {
    ctx: Context;
    push_context ctx {
        // The main viewport (owned by the application) will always have RendererUserData == nullptr since we didn't create the data for it.
        vd := cast(*ImGui_ImplDX11_ViewportData)viewport.RendererUserData;
        if vd {
            if vd.SwapChain
                IUnknown_Release(vd.SwapChain);
            vd.SwapChain = null;

            if vd.RTView
                IUnknown_Release(vd.RTView);
            vd.RTView = null;

            free(vd);
        }
        viewport.RendererUserData = null;
    }
}

ImGui_ImplDX11_SetWindowSize :: (viewport: *ImGui.Viewport, size: ImGui.ImVec2) #c_call {
    ctx: Context;
    push_context ctx {
        bd := ImGui_ImplDX11_GetBackendData();
        vd := cast(*ImGui_ImplDX11_ViewportData)viewport.RendererUserData;
        if vd.RTView {
            IUnknown_Release(vd.RTView);
            vd.RTView = null;
        }
        if vd.SwapChain {
            pBackBuffer: *ID3D11Texture2D;
            IDXGISwapChain_ResizeBuffers(vd.SwapChain, 0, cast(u32)size.x, cast(u32)size.y, .DXGI_FORMAT_UNKNOWN, 0);
            IDXGISwapChain_GetBuffer(vd.SwapChain, 0, *uid(ID3D11Texture2D_UUID), cast(**void)*pBackBuffer);
            if pBackBuffer == null {
                log_error("ImGui_ImplDX11_SetWindowSize() failed creating buffers.");
                return;
            }
            ID3D11Device_CreateRenderTargetView(bd.pd3dDevice, pBackBuffer, null, *vd.RTView);
            IUnknown_Release(pBackBuffer);
        }
    }
}

ImGui_ImplDX11_RenderWindow :: (viewport: *ImGui.Viewport, unused: *void) #c_call {
    ctx: Context;
    push_context ctx {
        bd := ImGui_ImplDX11_GetBackendData();
        vd := cast(*ImGui_ImplDX11_ViewportData)viewport.RendererUserData;
        clear_color : [4] float = .[ 0.0, 0.0, 0.0, 1.0 ];
        ID3D11DeviceContext_OMSetRenderTargets(bd.pd3dDeviceContext, 1, *vd.RTView, null);
        if !(viewport.Flags & .ImGuiViewportFlags_NoRendererClear)
            ID3D11DeviceContext_ClearRenderTargetView(bd.pd3dDeviceContext, vd.RTView, *clear_color);
        ImGui_ImplDX11_RenderDrawData(viewport.DrawData);
    }
}

ImGui_ImplDX11_SwapBuffers :: (viewport: *ImGui.Viewport, unused: *void) #c_call {
    ctx: Context;
    push_context ctx {
        vd := cast(*ImGui_ImplDX11_ViewportData)viewport.RendererUserData;
        IDXGISwapChain_Present(vd.SwapChain, 0, 0); // present without vsync
    }
}

ImGui_ImplDX11_InitPlatformInterface :: () {
    platform_io := ImGui.GetPlatformIO();
    platform_io.Renderer_CreateWindow  = ImGui_ImplDX11_CreateWindow;
    platform_io.Renderer_DestroyWindow = ImGui_ImplDX11_DestroyWindow;
    platform_io.Renderer_SetWindowSize = ImGui_ImplDX11_SetWindowSize;
    platform_io.Renderer_RenderWindow  = ImGui_ImplDX11_RenderWindow;
    platform_io.Renderer_SwapBuffers   = ImGui_ImplDX11_SwapBuffers;
}

ImGui_ImplDX11_ShutdownPlatformInterface :: () {
    ImGui.DestroyPlatformWindows();
}

// Custom Utility to get the offsets of a member
offset_of :: ($type: Type, member_name: string) -> offset: s64 {
    ti := type_info(type);
    for member : ti.members {
        if member.name == member_name {
            return member.offset_in_bytes;
        }
    }
    assert(false, tprint("'%' is not a member of '%'", member_name, ti.name));
    return 0; // Should never happen!
}

ImGui :: #import "ImGui";

#import "Basic";
#import "d3d11";
#import "d3d_compiler";
#import "dxgi";
